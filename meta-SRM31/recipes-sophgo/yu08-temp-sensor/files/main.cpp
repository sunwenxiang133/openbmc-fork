#include "yu08-config.hpp"
#include "yu08-reader.hpp"

#include <boost/asio/io_context.hpp>
#include <boost/asio/post.hpp>
#include <boost/asio/signal_set.hpp>
#include <boost/asio/steady_timer.hpp>
#include <boost/asio/thread_pool.hpp>

#include <sdbusplus/asio/connection.hpp>
#include <sdbusplus/asio/object_server.hpp>

#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdlib>
#include <exception>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <optional>
#include <stdexcept>
#include <string>
#include <tuple>
#include <utility>
#include <vector>

namespace {

constexpr const char *serviceName = "xyz.openbmc_project.YU08TempSensor";

constexpr const char *sensorRoot = "/xyz/openbmc_project/sensors";

using Interface = sdbusplus::asio::dbus_interface;
using Association = std::tuple<std::string, std::string, std::string>;

class TemperatureSensor {
public:
  TemperatureSensor(sdbusplus::asio::object_server &server,
                    const std::string &name, const std::string &inventoryPath) {
    const std::string path = std::string(sensorRoot) + "/temperature/" + name;

    value = server.add_interface(path, "xyz.openbmc_project.Sensor.Value");

    value->register_property("Value", std::numeric_limits<double>::quiet_NaN());

    value->register_property(
        "Unit", std::string("xyz.openbmc_project.Sensor.Value.Unit.DegreesC"));

    value->register_property("MinValue", 0.0);
    value->register_property("MaxValue", 255.0);

    availability = server.add_interface(
        path, "xyz.openbmc_project.State.Decorator.Availability");
    availability->register_property("Available", false);

    operational = server.add_interface(
        path, "xyz.openbmc_project.State.Decorator.OperationalStatus");
    operational->register_property("Functional", false);

    association = server.add_interface(
        path, "xyz.openbmc_project.Association.Definitions");

    std::vector<Association> associations;
    associations.emplace_back("chassis", "all_sensors", inventoryPath);
    association->register_property("Associations", associations);

    if (!value->initialize() || !availability->initialize() ||
        !operational->initialize() || !association->initialize()) {
      throw std::runtime_error("Failed to initialize sensor interfaces: " +
                               name);
    }
  }

  void update(const std::optional<int> &temperature) {
    if (temperature.has_value()) {
      value->set_property("Value", static_cast<double>(*temperature));

      operational->set_property("Functional", true);
      availability->set_property("Available", true);
    } else {
      availability->set_property("Available", false);
      operational->set_property("Functional", false);

      value->set_property("Value", std::numeric_limits<double>::quiet_NaN());
    }
  }

private:
  std::shared_ptr<Interface> value;
  std::shared_ptr<Interface> availability;
  std::shared_ptr<Interface> operational;
  std::shared_ptr<Interface> association;
};

} // namespace

int main() {
  try {
    boost::asio::io_context io;

    auto bus = std::make_shared<sdbusplus::asio::connection>(io);

    sdbusplus::asio::object_server server(bus, true);
    server.add_manager(sensorRoot);

    std::vector<yu08::DeviceConfig> devices;
    std::vector<std::unique_ptr<TemperatureSensor>> sensors;

    bus->request_name(serviceName);

    boost::asio::steady_timer timer(io);
    boost::asio::signal_set signals(io, SIGINT, SIGTERM);

    std::atomic_bool stopping{false};
    int exitCode = EXIT_SUCCESS;

    std::function<void(std::chrono::seconds)> schedule;

    // Declare the worker after the objects its tasks reference.
    boost::asio::thread_pool worker(1);

    schedule = [&](std::chrono::seconds delay) {
      if (stopping.load()) {
        return;
      }

      timer.expires_after(delay);

      timer.async_wait([&](const boost::system::error_code &ec) {
        if (ec == boost::asio::error::operation_aborted || stopping.load()) {
          return;
        }

        if (ec) {
          std::cerr << "YU08 timer failed: " << ec.message() << '\n';

          exitCode = EXIT_FAILURE;
          stopping.store(true);
          io.stop();
          return;
        }

        boost::asio::post(worker, [&]() {
          try {
            if (devices.empty()) {
              std::vector<yu08::DeviceConfig> loaded;
              try {
                loaded = yu08::loadConfiguration();
              } catch (const std::exception &error) {
                std::cerr << "YU08 configuration unavailable or invalid: "
                          << error.what() << '\n';
              }
              boost::asio::post(io, [&, loaded = std::move(loaded)]() mutable {
                if (stopping.load())
                  return;
                if (loaded.empty()) {
                  schedule(std::chrono::seconds(3));
                  return;
                }
                sensors.reserve(loaded.size() * 2);
                for (const auto &device : loaded) {
                  sensors.emplace_back(std::make_unique<TemperatureSensor>(
                      server, device.chipSensorName, device.inventoryPath));
                  sensors.emplace_back(std::make_unique<TemperatureSensor>(
                      server, device.boardSensorName, device.inventoryPath));
                  std::clog << "Configured YU08 bus=" << device.bus
                            << " address=0x" << std::hex << device.address
                            << std::dec << " chip=" << device.chipSensorName
                            << " board=" << device.boardSensorName << '\n';
                }
                devices = std::move(loaded);
                std::clog << "Loaded " << devices.size()
                          << " YU08 configurations\n";
                schedule(std::chrono::seconds(0));
              });
              return;
            }

            std::vector<Yu08Reading> readings(devices.size());
            for (std::size_t chip = 0; chip < devices.size(); ++chip) {
              if (stopping.load())
                return;
              readings[chip] =
                  readYu08(devices[chip].bus, devices[chip].address);
            }

            // All D-Bus updates run on the main event loop.
            boost::asio::post(io, [&, readings = std::move(readings)]() {
              if (stopping.load()) {
                return;
              }

              for (std::size_t chip = 0; chip < readings.size(); ++chip) {
                sensors[chip * 2]->update(readings[chip].chipTemperature);

                sensors[chip * 2 + 1]->update(readings[chip].boardTemperature);
              }

              schedule(std::chrono::seconds(3));
            });
          } catch (const std::exception &e) {
            std::cerr << "YU08 collection failed: " << e.what() << '\n';

            boost::asio::post(io, [&]() {
              exitCode = EXIT_FAILURE;
              stopping.store(true);
              io.stop();
            });
          }
        });
      });
    };

    signals.async_wait([&](const boost::system::error_code &ec, int signal) {
      if (!ec) {
        std::clog << "Stopping YU08 service, signal=" << signal << '\n';
      }

      stopping.store(true);
      timer.cancel();
      io.stop();
    });

    std::clog << "YU08 temperature service started\n";

    schedule(std::chrono::seconds(0));
    try {
      io.run();
    } catch (...) {
      stopping.store(true);
      timer.cancel();
      io.stop();
      worker.join();
      throw;
    }

    stopping.store(true);
    worker.join();

    std::clog << "YU08 temperature service stopped\n";
    return exitCode;
  } catch (const std::exception &e) {
    std::cerr << "YU08 service failed: " << e.what() << '\n';
    return EXIT_FAILURE;
  }
}
