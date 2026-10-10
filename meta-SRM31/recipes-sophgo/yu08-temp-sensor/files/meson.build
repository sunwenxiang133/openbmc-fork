project(
    'yu08-temp-sensor',
    'cpp',
    version: '0.1',
    default_options: [
        'cpp_std=c++20',
        'warning_level=3',
    ],
)

cpp = meson.get_compiler('cpp')

boost_dep = dependency('boost')
threads_dep = dependency('threads')
sdbusplus_dep = dependency('sdbusplus')
i2c_dep = cpp.find_library('i2c', required: true)

executable(
    'yu08-temp-sensor',
    [
        'main.cpp',
        'yu08-reader.cpp',
        'yu08-config.cpp',
        'yu08-config-dbus.cpp',
    ],
    dependencies: [
        boost_dep,
        threads_dep,
        sdbusplus_dep,
        i2c_dep,
    ],
    cpp_args: [
        '-DBOOST_ERROR_CODE_HEADER_ONLY',
        # sdbusplus.pc disables threads, but collection uses a thread pool.
        '-UBOOST_ASIO_DISABLE_THREADS',
    ],
    install: true,
    install_dir: get_option('bindir'),
)
