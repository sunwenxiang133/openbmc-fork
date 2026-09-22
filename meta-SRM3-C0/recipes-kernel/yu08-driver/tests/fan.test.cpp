#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <iostream>
#include <limits>
#include <map>
#include <string>

namespace boost { namespace system { using error_code = int; }
namespace asio { namespace error { constexpr int operation_aborted = 1; } } }
namespace sdbusplus::xyz::openbmc_project::Sensor::Device::Error {
struct FanFault {};
struct TempReadFailure {};
}
namespace phosphor::logging { template<class T> void report() {} }
struct Config {
    std::string readPath, dbusName;
    bool state = true, isInherent = true, accessibility = true;
    double fanFaultThreshold = 80, shutdownThreshold = 100;
    int findInputIndex(double value) { return value >= 75 ? 1 : 0; }
    double getOutputValue(int index) { return index ? 80 : 45; }
};
std::map<std::string, Config> g_fanDataMap, g_tempDataMap;
std::map<std::string, double> values;
std::map<std::string, std::string> controlModeMap{{"low", "FanLowSpeed"}};
std::map<std::string, double> controlParamMap{{"FanLowSpeed", 30}};
std::string g_fanControlMode = "auto";
bool isPowerOn = true, g_forceFullSpeed = false;
double g_outputRpmPre = 45, g_outputRpmCru = 45, written = -1;
std::atomic<double> g_outputRpmTar{45};
auto g_time_point = std::chrono::high_resolution_clock::now();
constexpr double PWM_MAX = 255;
int conn = 0, shutdowns = 0;
double readTempValue(std::string path, std::string) { return values.at(path); }
double readFanTachValue(std::string path, std::string) { return values.at(path); }
void forcePowerOff(int) { ++shutdowns; }
void repeat_sensor_monitor_timer() {}
void writeAllFansPwm(double pwm) { written = pwm; }
double percentageToActual(double percent, double maximum) { return percent * maximum / 100; }
bool isAutoControlMode() { return g_fanControlMode == "auto"; }

#include "fan-monitor.inc"

int main()
{
    g_fanDataMap["fan0"].readPath = "tach";
    values["tach"] = 6000;
    for (int i = 0; i < 16; ++i) {
        const auto name = "temp" + std::to_string(i);
        g_tempDataMap[name].readPath = name;
        values[name] = 50;
    }
    cycle_sensor_monitor(0);
    assert(!g_forceFullSpeed && g_outputRpmTar == 45);
    values["temp15"] = 76;
    cycle_sensor_monitor(0);
    assert(g_outputRpmTar == 80);
    values["temp15"] = std::numeric_limits<double>::quiet_NaN();
    cycle_sensor_monitor(0);
    assert(g_forceFullSpeed && written == 255 && g_outputRpmCru == 100);
    g_fanControlMode = "low";
    written = -1;
    cycle_sensor_monitor(0);
    assert(written == 255);
    values["temp15"] = 50;
    cycle_sensor_monitor(0);
    assert(!g_forceFullSpeed && written == 76.5);
    values["temp0"] = -1;
    values["temp9"] = 101;
    cycle_sensor_monitor(0);
    assert(g_forceFullSpeed && shutdowns == 1 && written == 255);
    values["temp0"] = values["temp9"] = 50;
    values["tach"] = 0;
    cycle_sensor_monitor(0);
    assert(g_forceFullSpeed && written == 255);
    written = -1;
    cycle_sensor_monitor(boost::asio::error::operation_aborted);
    assert(written == -1);
    isPowerOn = false;
    cycle_sensor_monitor(0);
    assert(written == -1);
    std::cout << "PASS: all-channel policy, immediate failsafe, manual override, recovery and shutdown\n";
}
