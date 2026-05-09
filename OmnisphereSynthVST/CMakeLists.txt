cmake_minimum_required(VERSION 3.22)
project(SuperNovaPad VERSION 1.0.0)
set(CMAKE_CXX_STANDARD 17)

# Auto-fetch JUCE — no manual clone needed
include(FetchContent)
FetchContent_Declare(
    JUCE
    GIT_REPOSITORY https://github.com/juce-framework/JUCE.git
    GIT_TAG        7.0.9
)
FetchContent_MakeAvailable(JUCE)

juce_add_plugin(SuperNovaPad
    COMPANY_NAME            "TommyStrand"
    IS_SYNTH                TRUE
    NEEDS_MIDI_INPUT        TRUE
    NEEDS_MIDI_OUTPUT       FALSE
    IS_MIDI_EFFECT          FALSE
    EDITOR_WANTS_KEYBOARD_FOCUS FALSE
    COPY_PLUGIN_AFTER_BUILD FALSE
    PLUGIN_MANUFACTURER_CODE TmSt
    PLUGIN_CODE             SnPd
    FORMATS                 VST3 AU Standalone
    PRODUCT_NAME            "SuperNovaPad"
    VST3_CATEGORIES         Instrument Synth
)

juce_generate_juce_header(SuperNovaPad)

target_sources(SuperNovaPad PRIVATE
    Source/PluginProcessor.cpp
    Source/PluginEditor.cpp
    Source/OmniVoice.cpp
)

target_include_directories(SuperNovaPad PRIVATE Source/Effects)

target_compile_definitions(SuperNovaPad PUBLIC
    JUCE_WEB_BROWSER=0
    JUCE_USE_CURL=0
    JUCE_VST3_CAN_REPLACE_VST2=0
    JUCE_DISPLAY_SPLASH_SCREEN=0
)

target_link_libraries(SuperNovaPad
    PRIVATE
        juce::juce_audio_basics
        juce::juce_audio_devices
        juce::juce_audio_formats
        juce::juce_audio_plugin_client
        juce::juce_audio_processors
        juce::juce_audio_utils
        juce::juce_core
        juce::juce_data_structures
        juce::juce_dsp
        juce::juce_events
        juce::juce_graphics
        juce::juce_gui_basics
        juce::juce_gui_extra
    PUBLIC
        juce::juce_recommended_config_flags
        juce::juce_recommended_lto_flags
        juce::juce_recommended_warning_flags
)
