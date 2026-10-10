#include "yu08-config.hpp"

#include <sdbusplus/bus.hpp>
#include <sdbusplus/message/types.hpp>

namespace yu08
{
std::vector<DeviceConfig> loadConfiguration()
{
    // Worker-local connection: never share the main event loop's connection.
    auto bus = sdbusplus::bus::new_system();
    auto method = bus.new_method_call(
        "xyz.openbmc_project.EntityManager",
        "/xyz/openbmc_project/inventory",
        "org.freedesktop.DBus.ObjectManager",
        "GetManagedObjects");
    // Bound configuration waits independently of the default D-Bus timeout.
    auto reply = bus.call(method, 2'000'000);
    std::map<sdbusplus::message::object_path, Interfaces> snapshot;
    reply.read(snapshot);
    ConfigurationObjects objects;
    for (auto& [path, interfaces] : snapshot)
        objects.emplace(path.str, std::move(interfaces));
    return parseConfiguration(objects);
}
} // namespace yu08
