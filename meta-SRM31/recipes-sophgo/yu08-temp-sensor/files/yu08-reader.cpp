#include "yu08-reader.hpp"

#include <linux/i2c-dev.h>
#include <sys/ioctl.h>
#include <fcntl.h>
#include <unistd.h>

extern "C"
{
#include <i2c/smbus.h>
}

#include <cerrno>
#include <cstdint>
#include <iostream>
#include <string>
#include <system_error>

namespace
{

constexpr std::uint8_t chipTemperatureRegister = 0x00;
constexpr std::uint8_t boardTemperatureRegister = 0x01;

class FileDescriptor
{
  public:
    explicit FileDescriptor(int fd) : fd(fd) {}

    ~FileDescriptor()
    {
        if (fd >= 0)
        {
            ::close(fd);
        }
    }

    FileDescriptor(const FileDescriptor&) = delete;
    FileDescriptor& operator=(const FileDescriptor&) = delete;

    int get() const
    {
        return fd;
    }

  private:
    int fd;
};

void logError(int bus, int address, const char* operation, int error)
{
    std::cerr << "YU08 bus=" << bus
              << " address=0x" << std::hex << address << std::dec
              << " " << operation << ": "
              << std::system_category().message(error) << '\n';
}

std::optional<int> readTemperature(int fd, int bus, int address,
                                   std::uint8_t command,
                                   const char* operation)
{
    const int value = i2c_smbus_read_byte_data(fd, command);

    if (value < 0)
    {
        const int error = errno;
        logError(bus, address, operation, error);
        return std::nullopt;
    }

    // The protocol reports an unsigned byte in degrees Celsius.
    return value;
}

} // namespace

Yu08Reading readYu08(int bus, int address)
{
    Yu08Reading reading;

    const std::string path = "/dev/i2c-" + std::to_string(bus);
    FileDescriptor fd(::open(path.c_str(), O_RDWR | O_CLOEXEC));

    if (fd.get() < 0)
    {
        const int error = errno;
        logError(bus, address, "open adapter failed", error);
        return reading;
    }

    unsigned long functions = 0;

    if (::ioctl(fd.get(), I2C_FUNCS, &functions) < 0)
    {
        const int error = errno;
        logError(bus, address, "query adapter functions failed", error);
        return reading;
    }

    if ((functions & I2C_FUNC_SMBUS_READ_BYTE_DATA) == 0)
    {
        std::cerr << "YU08 bus=" << bus
                  << " does not support SMBus Read Byte Data\n";
        return reading;
    }

    // Do not force access to an address owned by a kernel driver.
    if (::ioctl(fd.get(), I2C_SLAVE, address) < 0)
    {
        const int error = errno;
        logError(bus, address, "select slave failed", error);
        return reading;
    }

    reading.chipTemperature =
        readTemperature(fd.get(), bus, address,
                        chipTemperatureRegister,
                        "read chip temperature failed");

    reading.boardTemperature =
        readTemperature(fd.get(), bus, address,
                        boardTemperatureRegister,
                        "read board temperature failed");

    return reading;
}