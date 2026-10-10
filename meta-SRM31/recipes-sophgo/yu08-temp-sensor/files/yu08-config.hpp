#pragma once

#include <cstdint>
#include <map>
#include <string>
#include <tuple>
#include <variant>
#include <vector>

namespace yu08
{
inline constexpr const char* configurationInterface =
    "xyz.openbmc_project.Configuration.YU08";

struct DeviceConfig
{
    int bus;
    int address;
    std::string chipSensorName;
    std::string boardSensorName;
    std::string inventoryPath;
};

// Types published by this version of Entity Manager, including associations.
using Property = std::variant<bool, int64_t, uint64_t, double, std::string,
    std::vector<int64_t>, std::vector<uint64_t>, std::vector<double>,
    std::vector<std::string>,
    std::vector<std::tuple<std::string, std::string, std::string>>>;
using Properties = std::map<std::string, Property>;
using Interfaces = std::map<std::string, Properties>;
using ConfigurationObjects = std::map<std::string, Interfaces>;

std::vector<DeviceConfig> parseConfiguration(const ConfigurationObjects& objects);
std::vector<DeviceConfig> loadConfiguration();
} // namespace yu08
