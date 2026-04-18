#include <fstream>
#include <print>
#include <iostream>
#include <filesystem>
#include <vector>
#include <string>
#include <iomanip>

#define NX_BACKEND uint64_t
#include <nxsim/simulation.h>

using namespace nxon;

const static auto magic_instr = value_t{32, 0xdead10cc};

auto high = value_t{1, 1};
auto low = value_t{1, 0};

unsigned singed_extend(const unsigned size, const unsigned value) {
    if (value & 1 << (size - 1)) {
        return value | ~((1 << size) - 1);
    }
    return value;
}

class Memory {
    static constexpr unsigned MEMORY_SIZE = 32768;

    std::vector<std::byte> memory;

    [[nodiscard]] unsigned read_bytes(unsigned addr, const unsigned offset) const {
        addr &= MEMORY_SIZE - 1;
        unsigned result = 0;
        for (unsigned i = 0; i != offset; ++i) {
            result <<= 8;
            result |= static_cast<unsigned>(memory[addr + offset - i - 1]);
        }
        return result;
    }

    void write_bytes(unsigned addr, unsigned value, const unsigned offset) {
        addr &= MEMORY_SIZE - 1;
        for (unsigned i = 0; i != offset; ++i) {
            memory[addr + i] = static_cast<std::byte>(value & 0xFF);
            value >>= 8;
        }
    }

public:
    explicit Memory(std::ifstream fin) {
        memory.resize(MEMORY_SIZE);

        std::string line;
        unsigned addr = 0;
        while (std::getline(fin, line)) {
            if (line.empty()) continue;
            if (line[0] == '@') {
                addr = std::stoul(line.substr(1), nullptr, 16) << 2;
            } else {
                unsigned value = std::stoul(line, nullptr, 16);
                for (int i = 0; i < 4; ++i) {
                    memory[addr++] = static_cast<std::byte>(value & 0xFF);
                    value >>= 8;
                }
            }
        }
    }

    [[nodiscard]] value_t read_word(const unsigned addr) const {
        return {32, read_bytes(addr, 4)};
    }

    [[nodiscard]] value_t read_word(const value_t &addr) const {
        return read_word(static_cast<unsigned>(addr));
    }

    [[nodiscard]] value_t read_with_op(const value_t &memOP, const unsigned addr) const {
        switch (static_cast<unsigned>(memOP)) {
            case 0b000u : return {32, singed_extend(8, read_bytes(addr, 1))};
            case 0b001u : return {32, singed_extend(16, read_bytes(addr, 2))};
            case 0b010u : return {32, read_bytes(addr, 4)};
            case 0b101u : return {32, read_bytes(addr, 2)};
            case 0b100u : return {32, read_bytes(addr, 1)};
            default : {
                std::cout << "Invalid read memory operation: " << static_cast<unsigned>(memOP) << std::endl;
                std::abort();
            }
        }
    }

    [[nodiscard]] value_t read_with_op(const value_t &memOP, const value_t &addr) const {
        return read_with_op(memOP, static_cast<unsigned>(addr));
    }

    void write_with_op(const value_t &memOP, const unsigned addr, const value_t &value) {
        switch (static_cast<unsigned>(memOP)) {
            case 0b000u : write_bytes(addr, static_cast<unsigned>(value) & 0xFFu, 1); break;
            case 0b001u : write_bytes(addr, static_cast<unsigned>(value) & 0xFFFFu, 2); break;
            case 0b010u : write_bytes(addr, static_cast<unsigned>(value), 4); break;
            case 0b101u : write_bytes(addr, static_cast<unsigned>(value) & 0xFFFFu, 2); break;
            case 0b100u : write_bytes(addr, static_cast<unsigned>(value) & 0xFFu, 1); break;
            default : {
                std::cout << "Invalid write memory operation: " << static_cast<unsigned>(memOP) << std::endl;
                std::abort();
            }
        }
    }

    void write_with_op(const value_t &memOP, const value_t &addr, const value_t &value) {
        write_with_op(memOP, static_cast<unsigned>(addr), value);
    }
};

namespace nxon::impl {
    struct alu_rule final : rule_impl {
        source_t a, b, alu_ctl;
        sink_t result, zero, less;

        alu_rule(const source_t a, const source_t b, const source_t alu_ctl,
                 const sink_t result, const sink_t zero, const sink_t less)
            : rule_impl(
                a.dependencies() + b.dependencies() + alu_ctl.dependencies(),
                result.outcomes() + zero.outcomes() + less.outcomes()
            ),
            a(a), b(b), alu_ctl(alu_ctl), result(result), zero(zero), less(less) {}

        id_set perform(value_storage &values) const override {
            const auto a_val = a.get(values);
            const auto b_val = b.get(values);
            const auto ctl = static_cast<uint64_t>(alu_ctl.get(values));

            value_t res;
            switch (ctl) {
                case 0b0000u : res = a_val + b_val; break; // ADD
                case 0b1000u : res = a_val - b_val; break; // SUB
                case 0b0001u :
                case 0b1001u : res = a_val << static_cast<unsigned>(b_val.unsigned_resize(5)); break; // SLL
                case 0b0010u : res = value_t{32, a_val.signed_compare(b_val) == std::strong_ordering::less}; break; // SLT
                case 0b1010u : res = value_t{32, a_val <=> b_val == std::strong_ordering::less}; break; // SLTU
                case 0b0011u :
                case 0b1011u : res = b_val; break;
                case 0b0100u :
                case 0b1100u : res = a_val ^ b_val; break; // XOR
                case 0b0101u : res = a_val >> static_cast<unsigned>(b_val.unsigned_resize(5)); break; // SRL
                case 0b1101u : res = a_val.arithmetic_shr(static_cast<unsigned>(b_val.unsigned_resize(5))); break; // SRA
                case 0b0110u :
                case 0b1110u : res = a_val | b_val; break; // OR
                case 0b0111u :
                case 0b1111u : res = a_val & b_val; break; // AND
                default: std::unreachable();
            }

            std::vector<id_t> changes;
            if (result.update_if_changed(values, res)) {
                changes.insert(changes.end(), result.outcomes().begin(), result.outcomes().end());
            }

            if (const auto next_zero = value_t{1, ctl == 0b0010 || ctl == 0b1010 ? a_val == b_val : static_cast<uint64_t>(res) == 0};
                zero.update_if_changed(values, next_zero)) {
                changes.insert(changes.end(), zero.outcomes().begin(), zero.outcomes().end());
            }

            if (const auto next_less = value_t{1, static_cast<uint64_t>(res)}; less.update_if_changed(values, next_less)) {
                changes.insert(changes.end(), less.outcomes().begin(), less.outcomes().end());
            }
            return id_set{changes.begin(), changes.end()};
        }

        static rule_t parse(const parse_context &ctx, const nlohmann::json &json) {
            return make_rule<alu_rule>(ctx, json,
                source_in<0>, source_in<1>, source_in<2>,
                sink_out<0>,  sink_out<1>,  sink_out<2>
            );
        }
    };
}

int main(int argc, char *argv[]) {
    bool enable_native = true;
    bool enable_trace = false;
    std::vector<std::string> test_dirs;
    std::vector<std::string> test_files;
    for (int i = 1; i < argc; ++i) {
        const std::string arg = argv[i];
        if (arg == "--no-native") {
            enable_native = false;
        }
        if (arg == "--trace") {
            enable_trace = true;
        }
        if (arg == "--dir" && i + 1 < argc) {
            test_dirs.push_back(argv[++i]);
        }
        if (arg == "--file" && i + 1 < argc) {
            test_files.push_back(argv[++i]);
        }
    }
    if (test_dirs.empty() && test_files.empty()) {
        test_dirs.push_back("testcases");
    }
    
    std::string json;
    std::getline(std::cin, json);
    const auto native_rules = native_map{{"ALU", std::function(impl::alu_rule::parse)}};

    auto run_suite = [&](auto &ctx) {
        int passed = 0, total = 0;
        using namespace std::chrono;
        duration<double> total_simulation_seconds{0.0};

        auto run_file = [&](const std::filesystem::path &input_path, int max_cycles = 100000) {
            std::filesystem::path file_path = input_path;
            if (!file_path.is_absolute()) {
                file_path = std::filesystem::current_path() / file_path;
            }

            if (!std::filesystem::exists(file_path)) {
                std::cerr << "Warning: test file not found: " << input_path << "\n";
                return;
            }
            if (file_path.extension() != ".hex") {
                std::cerr << "Warning: test file must be a .hex file: " << input_path << "\n";
                return;
            }

            total++;
            std::cout << "Running test case: " << file_path.filename();
            const auto sim_start = high_resolution_clock::now();

            const auto data_path = file_path.parent_path() / file_path.stem();
            const auto instr_mem = new Memory(std::ifstream(file_path));
            const auto data_mem  = new Memory(std::ifstream(data_path.string() + ".data"));

            ctx.set("rst", value_t{1, 1});
            ctx.flip("clk");
            ctx.flip("clk");
            ctx.set("rst", value_t{1, 0});

            for (int i = 0; i != max_cycles; ++i) {
                const auto fetch_pc = ctx.get("imem_addr");
                const auto instr = instr_mem->read_word(fetch_pc);

                if (enable_trace) {
                    std::cout << std::endl
                              << "Cycle " << std::setw(5) << i << ": " << std::hex
                              << "PC = 0x"          << std::setw(5) << std::setfill('0') << static_cast<unsigned>(fetch_pc) << ", "
                              << "Instruction = 0x" << std::setw(8) << std::setfill('0') << static_cast<unsigned>(instr) << ", "
                              << std::dec;
                }

                ctx.set("instr", instr);

                auto d_mem_op   = ctx.get("dmem_op");
                auto d_mem_addr = ctx.get("dmem_addr");
                if (ctx.get("dmem_wr") == high) {
                    auto d_mem_in = ctx.get("dmem_in");
                    data_mem->write_with_op(d_mem_op, d_mem_addr, d_mem_in);
                }

                if (static_cast<unsigned>(ctx.get("x10")) == 0x00c0ffee) {
                    std::cout << "\t-> \033[32mPassed!\033[0m" << std::endl;
                    passed++;
                    break;
                }

                ctx.set("dmem_out", data_mem->read_with_op(d_mem_op, d_mem_addr));
                ctx.flip("clk");
                ctx.flip("clk");
            }

            delete instr_mem;
            delete data_mem;
            total_simulation_seconds += high_resolution_clock::now() - sim_start;
        };

        auto run_dir = [&](const std::string& dir_name, int max_cycles = 100000) {
            std::filesystem::path dir = std::filesystem::current_path() / dir_name;
            if (!std::filesystem::is_directory(dir)) {
                std::cerr << "Warning: test directory not found: " << dir_name << "\n";
                return;
            }
            std::cout << "\n=== Running tests from '" << dir_name << "' ===\n";

            for (const auto& entry : std::filesystem::directory_iterator(dir)) {
                const std::filesystem::path file_path = entry.path();

                if (file_path.extension() == ".data") continue;
                if (file_path.extension() != ".hex")  continue;
                if (file_path.filename() == "fence_i.hex") continue;

                run_file(file_path, max_cycles);
            }
        };

        for (const auto& d : test_dirs) {
            run_dir(d);
        }
        for (const auto& f : test_files) {
            run_file(f);
        }

        std::print("\nPassed {}/{} test cases\n", passed, total);
        std::cout << "Elapsed time: " << total_simulation_seconds.count() << "s\n";
        return passed == total ? 0 : 1;
    };

    parse_context ctx;
    if (enable_native) {
        parse_circuit(ctx, json, native_rules);
    } else {
        parse_circuit(ctx, json);
    }
    return run_suite(ctx);
}
