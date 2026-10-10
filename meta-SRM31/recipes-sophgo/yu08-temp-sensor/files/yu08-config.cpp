#include "yu08-config.hpp"

#include <cmath>
#include <limits>
#include <set>
#include <stdexcept>
#include <utility>

namespace yu08
{
namespace
{
int integer(const Property& value, int minimum, int maximum)
{
    double number;
    if (const auto* v = std::get_if<uint64_t>(&value))
        number = static_cast<double>(*v);
    else if (const auto* v = std::get_if<int64_t>(&value))
        number = static_cast<double>(*v);
    else if (const auto* v = std::get_if<double>(&value))
        number = *v;
    else
        throw std::runtime_error("expected a numeric property");

    if (!std::isfinite(number) || number != std::floor(number) ||
        number < minimum || number > maximum)
        throw std::runtime_error("integer property out of range");
    return static_cast<int>(number);
}

std::string name(const Property& value)
{
    const auto* result = std::get_if<std::string>(&value);
    if (!result || result->empty() || result->find_first_not_of(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_") !=
        std::string::npos)
        throw std::runtime_error("sensor name must use letters, digits or underscores");
    return *result;
}
} // namespace

std::vector<DeviceConfig> parseConfiguration(const ConfigurationObjects& objects)
{
    std::vector<DeviceConfig> devices;
    std::set<std::string> names;
    std::set<std::pair<int, int>> addresses;
    for (const auto& [path, interfaces] : objects)
    {
        auto config = interfaces.find(configurationInterface);
        if (config == interfaces.end())
            continue;
        try
        {
            const auto& props = config->second;
            DeviceConfig device{};
            device.bus = integer(props.at("Bus"), 0, std::numeric_limits<int>::max());
            device.address = integer(props.at("Address"), 0x08, 0x77);
            device.chipSensorName = name(props.at("Name"));
            device.boardSensorName = name(props.at("Name1"));
            const auto slash = path.rfind('/');
            if (slash == std::string::npos || slash == 0)
                throw std::runtime_error("invalid configuration path");
            device.inventoryPath = path.substr(0, slash);
            const auto parent = objects.find(device.inventoryPath);
            if (parent == objects.end() ||
                (!parent->second.contains("xyz.openbmc_project.Inventory.Item.Board") &&
                 !parent->second.contains("xyz.openbmc_project.Inventory.Item.Chassis")))
                throw std::runtime_error("configuration parent is not a board or chassis");
            if (!addresses.emplace(device.bus, device.address).second)
                throw std::runtime_error("duplicate bus/address");
            if (!names.insert(device.chipSensorName).second ||
                !names.insert(device.boardSensorName).second)
                throw std::runtime_error("duplicate sensor name");
            devices.push_back(std::move(device));
        }
        catch (const std::exception& error)
        {
            throw std::runtime_error(path + ": " + error.what());
        }
    }
    return devices;
}
} // namespace yu08
