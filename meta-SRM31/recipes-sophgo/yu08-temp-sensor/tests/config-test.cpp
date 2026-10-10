#include "yu08-config.hpp"
#include <cassert>
#include <functional>
#include <iostream>
#include <limits>
#include <stdexcept>

static void rejects(const std::function<void()>& action)
{
    bool rejected = false;
    try { action(); } catch (const std::exception&) { rejected = true; }
    assert(rejected);
}

int main()
{
    using namespace yu08;
    Properties props{{"Bus", uint64_t{16}}, {"Address", double{96}},
                     {"Name", std::string("Chip0")},
                     {"Name1", std::string("Board0")}};
    const std::string parent = "/xyz/openbmc_project/inventory/system/board/TestBoard";
    ConfigurationObjects objects{{parent, {{"xyz.openbmc_project.Inventory.Item.Board", {}}}},
        {parent + "/Chip0", {{configurationInterface, props}}}};
    auto parsed = parseConfiguration(objects);
    assert(parsed.size() == 1);
    assert(parsed[0].bus == 16 && parsed[0].address == 0x60);
    assert(parsed[0].inventoryPath == parent);
    assert(parsed[0].chipSensorName == "Chip0");
    assert(parseConfiguration({}).empty());
    auto bad = objects;
    bad[parent + "/Chip0"][configurationInterface]["Bus"] = 16.5;
    rejects([&] { parseConfiguration(bad); });
    bad = objects;
    bad[parent + "/Chip0"][configurationInterface]["Address"] = uint64_t{128};
    rejects([&] { parseConfiguration(bad); });
    bad = objects;
    bad[parent + "/Chip0"][configurationInterface]["Address"] = std::numeric_limits<double>::quiet_NaN();
    rejects([&] { parseConfiguration(bad); });
    bad = objects;
    bad[parent + "/Chip0"][configurationInterface].erase("Name1");
    rejects([&] { parseConfiguration(bad); });
    bad = objects;
    bad[parent + "/Chip0"][configurationInterface]["Name"] = std::string("bad/name");
    rejects([&] { parseConfiguration(bad); });
    bad = objects;
    bad[parent + "/Other"] = bad[parent + "/Chip0"];
    rejects([&] { parseConfiguration(bad); });
    bad[parent + "/Other"][configurationInterface]["Address"] = uint64_t{97};
    rejects([&] { parseConfiguration(bad); });
    bad = objects;
    bad.erase(parent);
    rejects([&] { parseConfiguration(bad); });
    objects[parent + "/Chip1"] = {{configurationInterface, {
        {"Bus", int64_t{7}}, {"Address", uint64_t{97}},
        {"Name", std::string("Chip1")}, {"Name1", std::string("Board1")}}}};
    assert(parseConfiguration(objects).size() == 2);
    std::cout << "Configuration parser tests passed\n";
}
