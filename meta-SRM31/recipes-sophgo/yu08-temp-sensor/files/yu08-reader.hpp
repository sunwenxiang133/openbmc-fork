#pragma once

#include <optional>

struct Yu08Reading
{
    std::optional<int> chipTemperature;
    std::optional<int> boardTemperature;
};

Yu08Reading readYu08(int bus, int address);