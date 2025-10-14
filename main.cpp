#include <fstream>
#include <print>
#include <iostream>
#include <filesystem>

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

        alu_rule(source_t a, source_t b, source_t alu_ctl, sink_t result, sink_t zero, sink_t less)
            : rule_impl(
                a.dependencies() + b.dependencies() + alu_ctl.dependencies(),
                result.outcomes() + zero.outcomes() + less.outcomes()
            ),
            a(std::move(a)), 
            b(std::move(b)), 
            alu_ctl(std::move(alu_ctl)),
            result(std::move(result)), 
            zero(std::move(zero)), 
            less(std::move(less)) {}

        indirect_id_set perform(value_storage &values) const override {
            const auto a_val = *a.get(values);
            const auto b_val = *b.get(values);
            const auto ctl = static_cast<uint64_t>(*alu_ctl.get(values));

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
            if (result.check(values, res)) {
                result.put(values, res);
                changes.insert(changes.end(), result.outcomes().begin(), result.outcomes().end());
            }

            if (const auto next_zero = value_t{1, ctl == 0b0010 || ctl == 0b1010 ? a_val == b_val : static_cast<uint64_t>(res) == 0}; zero.check(values, next_zero)) {
                zero.put(values, next_zero);
                changes.insert(changes.end(), zero.outcomes().begin(), zero.outcomes().end());
            }

            if (const auto next_less = value_t{1, static_cast<uint64_t>(res)}; less.check(values, next_less)) {
                less.put(values, next_less);
                changes.insert(changes.end(), less.outcomes().begin(), less.outcomes().end());
            }
            return indirect_id_set(id_set{changes.begin(), changes.end()});
        }

        static rule_t parse(const parse_context &ctx, const nlohmann::json &json) {
            const auto &input = json["input"];
            const auto &output = json["output"];

            return rule_t{new alu_rule(
                parse_source(input.at(0), ctx),
                parse_source(input.at(1), ctx),
                parse_source(input.at(2), ctx),
                parse_sink(output.at(0), ctx),
                parse_sink(output.at(1), ctx),
                parse_sink(output.at(2), ctx)
            )};
        }
    };
}

int main(int argc, char *argv[]) {
    bool enable_native = true;
    enable_native = !(argc > 1 && std::string(argv[1]) == "--no-native");

    std::string json;
    std::getline(std::cin, json);
    partitioned_parse_context ctx;
    if (enable_native) {
        parse_circuit(ctx, json, {{"ALU", std::function(impl::alu_rule::parse)}});
    } else {
        parse_circuit(ctx, json);
    }
    ctx.init_partition();

    using namespace std::chrono;
    const auto start = high_resolution_clock::now();

    int passed = 0, total = 0;
    for (std::filesystem::path path = std::filesystem::current_path().append("testcases");
        const auto& entry : std::filesystem::directory_iterator(path)) {
        std::filesystem::path file_path = entry.path();

        if (file_path.extension() == ".data") {
            continue;
        }

        if (file_path.filename() == "fence_i.hex") {
            continue;
        }

        total++;
        std::cout << "Running test case: " << file_path.filename();

        const auto instr_mem = new Memory(std::ifstream(file_path));
        const auto data_mem = new Memory(std::ifstream(file_path.replace_extension(".data")));

        ctx.broadcast_flip_by_name("clk");
        ctx.broadcast_by_name("rst", value_t{1, 1});
        ctx.run_to_fixed();
        ctx.broadcast_flip_by_name("clk");
        ctx.run_to_fixed();
        ctx.broadcast_flip_by_name("clk");
        ctx.run_to_fixed();

        ctx.broadcast_by_name("rst", value_t{1, 0});
        ctx.run_to_fixed();

        for (int i = 0 ; i != 1000; ++i) {
            const auto instr = instr_mem->read_word(ctx.get_by_name("imem_addr"));
            ctx.broadcast_flip_by_name("clk");

            ctx.broadcast_by_name("instr", instr);
            ctx.run_to_fixed();

            auto d_mem_op = ctx.get_by_name("dmem_op");
            auto d_mem_addr = ctx.get_by_name("dmem_addr");
            if (ctx.get_by_name("dmem_wr") == high) {
                auto d_mem_in = ctx.get_by_name("dmem_in");
                data_mem->write_with_op(d_mem_op, d_mem_addr, d_mem_in);
            }

            if (instr == magic_instr) {
                if (static_cast<unsigned>(ctx.get_by_name("data[10]")) == 0x00c0ffee) {
                    std::cout << "\t-> \033[32mPassed!\033[0m" << std::endl;
                    passed++;
                } else {
                    std::cout << "\t-> \033[31mFailed!\033[0m" << std::endl;
                }
                break;
            }

            ctx.broadcast_flip_by_name("clk");
            ctx.broadcast_by_name("dmem_out", data_mem->read_with_op(d_mem_op, d_mem_addr));
            ctx.run_to_fixed();
        }
        delete instr_mem;
        delete data_mem;
    }
    std::print("Passed {}/{} test cases\n", passed, total);

    const auto end = high_resolution_clock::now();
    std::chrono::duration<double> elapsed_seconds = end - start;
    std::cout << "Elapsed time: " << elapsed_seconds.count() << "s\n";
    return 0;
}
