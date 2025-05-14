#include <fstream>
#include <filesystem>
#include <nxsim/circuit.h>
#include <nxsim/circuit_parser.h>

using namespace nxon;

unsigned singed_extend(const unsigned size, const unsigned value) {
    if (value & 1 << size) {
        return value | ~((1 << size) - 1);
    }
    return value;
}

class Memory {
    std::vector<std::byte> memory;

    [[nodiscard]] unsigned read_byte(const unsigned addr, const unsigned offset) const {
        unsigned result = 0;
        for (int i = 0; i != offset; ++i) {
            result <<= 8;
            result |= static_cast<unsigned>(memory[addr + i]);
        }
        return result;
    }

    void write_byte(const unsigned addr, unsigned value) {
        for (int i = 0; i != 4; ++i) {
            memory[addr + 3 - i] = static_cast<std::byte>(value & 0xFF);
            value >>= 8;
        }
    }

public:
    explicit Memory(std::ifstream fin) {
        std::string line;
        while (std::getline(fin, line)) {
            if (line.empty()) continue;
            unsigned value = std::stoul(line, nullptr, 16);
            for (int i = 0; i < 4; ++i) {
                memory.push_back(static_cast<std::byte>(value & 0xFF));
                value >>= 8;
            }
        }
    }

    [[nodiscard]] value_t read32(const unsigned addr) const {
        return {32, read_byte(addr, 4)};
    }

    [[nodiscard]] value_t read_with_op(const value_t &memOP, const unsigned addr) const {
        switch (memOP) {
            case 0b000 : return {32, singed_extend(8, read_byte(addr, 1))};
            case 0b001 : return {32, singed_extend(16, read_byte(addr, 2))};
            case 0b010 : return {32, read_byte(addr, 4)};
            case 0b101 : return {32, read_byte(addr, 2)};
            case 0b100 : return {32, read_byte(addr, 1)};
            default : assert(false);
        }
    }

    void write_with_op(const value_t &memOP, const unsigned addr, const value_t &value) {
        switch (memOP) {
            case 0b000 : write_byte(addr, singed_extend(8, static_cast<unsigned>(value) & 0xFF));
            case 0b001 : write_byte(addr, singed_extend(16, static_cast<unsigned>(value) & 0xFFFF));
            case 0b010 : write_byte(addr, static_cast<unsigned>(value));
            case 0b101 : write_byte(addr, static_cast<unsigned>(value) & 0xFFFF);
            case 0b100 : write_byte(addr, static_cast<unsigned>(value) & 0xFF);
            default : assert(false);
        }
    }
};

int main() {
    std::string json;
    std::getline(std::cin, json);
    auto ctx = parse_circuit(nlohmann::json::parse(json));

    auto time_advance = [&]() {
        ctx.flip_by_name("clk");
        ctx.flip_by_name("clk");
    };

    std::filesystem::path path = std::filesystem::current_path().append("testcases");
    for (const auto& entry : std::filesystem::directory_iterator(path)) {
        std::filesystem::path file_path = entry.path();
        if (file_path.extension() == ".data") {
            continue;
        }
        
        std::cout << "================="
                  << " Running test case: " << file_path.filename()
                  << " ================"
                  << std::endl;

        const auto instr_mem = new Memory(std::ifstream(file_path));
        const auto data_mem = new Memory(std::ifstream(file_path.replace_extension(".data")));

        ctx.update_by_name("rst", value_t{1, 1}); time_advance();
        ctx.update_by_name("rst", value_t{1, 0});

        const auto i_addr = static_cast<unsigned>(ctx.get_by_name("imemAddr"));
        const auto d_addr = static_cast<unsigned>(ctx.get_by_name("dmemAddr"));

        const static auto magic_instr = value_t{32, 0xdead10cc};
        if (const auto next_instr = instr_mem->read32(i_addr); next_instr == magic_instr) {
            std::cout << "End of Program" << std::endl;
        } else {
            ctx.update_by_name("imemDataOut", next_instr);

        }

        delete instr_mem;
        delete data_mem;
        break;
    }

    return 0;
}