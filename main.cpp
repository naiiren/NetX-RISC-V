#include <fstream>
#include <filesystem>
#include <format>
#include <nxsim/circuit.h>
#include <nxsim/circuit_parser.h>

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
        for (int i = 0; i != offset; ++i) {
            result <<= 8;
            result |= static_cast<unsigned>(memory[addr + offset - i - 1]);
        }
        return result;
    }

    void write_bytes(unsigned addr, unsigned value, const unsigned offset) {
        addr &= MEMORY_SIZE - 1;
        for (int i = 0; i != offset; ++i) {
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

void print(const std::string &head, const value_t &value) {
    std::cout << head << std::setw(8) << std::setfill('0') << std::hex << static_cast<unsigned>(value) << '\t';
}

int main() {
    std::string json;
    std::getline(std::cin, json);
    auto ctx = parse_circuit(nlohmann::json::parse(json));

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

        ctx.flip_by_name("clk");
        ctx.update_by_name("rst", value_t{1, 1});
        ctx.flip_by_name("clk");
        ctx.flip_by_name("clk");
        ctx.update_by_name("rst", value_t{1, 0});

        for (int i = 0 ; i != 1000; ++i) {
            const auto instr = instr_mem->read_word(ctx.circuit.get_value(4));
            ctx.flip_by_name("clk");

            ctx.update_by_name("instr", instr);

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

            ctx.flip_by_name("clk");
            ctx.update_by_name("dmem_out", data_mem->read_with_op(d_mem_op, d_mem_addr));
        }
        delete instr_mem;
        delete data_mem;
    }
    std::cout << std::format("Passed {}/{} test cases\n", passed, total);

    const auto end = high_resolution_clock::now();
    std::chrono::duration<double> elapsed_seconds = end - start;
    std::cout << "Elapsed time: " << elapsed_seconds.count() << "s\n";
    return 0;
}