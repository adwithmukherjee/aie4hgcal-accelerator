#pragma once
#include <cstdint>
namespace density {
constexpr unsigned hits=20, landmarks=128, dimensions=8;
constexpr unsigned payload_bytes=(hits+landmarks)*dimensions;
constexpr unsigned payload_words=payload_bytes/4;
constexpr unsigned distances=hits*landmarks;
constexpr unsigned count_words=landmarks/4;
constexpr unsigned output_words=count_words+distances;
constexpr uint32_t radius_squared=645;
}
