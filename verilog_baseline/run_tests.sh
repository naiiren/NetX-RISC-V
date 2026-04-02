#!/bin/bash

# Colors for output
RED='\033[31m'
GREEN='\033[32m'
RESET='\033[0m'

# Function to run a single test case
run_test() {
    local hex_file="$1"
    local data_file="$2"
    local test_name="$3"
    local simulation_time=0
    
    # Read testbench template and replace placeholders
    local testbench_content
    if ! testbench_content=$(cat "testbench_template.v"); then
        echo -e "${RED}Error: Could not read testbench_template.v${RESET}"
        return 1
    fi
    
    # Create absolute paths
    local abs_hex_file abs_data_file
    abs_hex_file=$(realpath "$hex_file")
    abs_data_file=$(realpath "$data_file")
    
    # Replace placeholders
    testbench_content="${testbench_content//\{\{HEX_FILE\}\}/$abs_hex_file}"
    testbench_content="${testbench_content//\{\{DATA_FILE\}\}/$abs_data_file}"
    testbench_content="${testbench_content//\{\{TEST_NAME\}\}/$test_name}"
    
    # Write temporary testbench
    if ! echo "$testbench_content" > "temp_testbench.v"; then
        echo -e "${RED}Error: Could not write temporary testbench${RESET}"
        return 1
    fi
    
    # Compile with iverilog (30 second timeout)
    local compile_output compile_exit_code
    if ! compile_output=$(timeout 30 iverilog -o temp_sim temp_testbench.v core.v 2>&1); then
        compile_exit_code=$?
        if [[ $compile_exit_code -eq 124 ]]; then
            echo -e "${RED}Compilation timeout for $test_name${RESET}"
        else
            echo -e "${RED}Compilation failed for $test_name:${RESET}"
            echo "$compile_output"
        fi
        cleanup_temp_files
        echo "0"  # Return simulation time
        return 1
    fi
    
    # Run simulation with timing (10 second timeout)
    local sim_output sim_exit_code sim_start sim_end
    sim_start=$(date +%s.%N)
    if sim_output=$(timeout 10 vvp temp_sim 2>&1); then
        sim_end=$(date +%s.%N)
        simulation_time=$(echo "$sim_end - $sim_start" | bc -l)
        
        # Print the first line of output (test result)
        echo "$(echo "$sim_output" | head -n1)"
        
        # Check if test passed
        if echo "$sim_output" | grep -q "Passed!"; then
            cleanup_temp_files
            echo "TIME:$simulation_time"
            return 0
        else
            cleanup_temp_files
            echo "TIME:$simulation_time"
            return 1
        fi
    else
        sim_exit_code=$?
        sim_end=$(date +%s.%N)
        simulation_time=$(echo "$sim_end - $sim_start" | bc -l)
        
        if [[ $sim_exit_code -eq 124 ]]; then
            printf "%sSimulation timeout for %s (simulation time: %.3fs)%s\n" "$RED" "$test_name" "$simulation_time" "$RESET"
        else
            echo -e "${RED}Simulation failed for $test_name${RESET}"
            echo "$sim_output"
        fi
        cleanup_temp_files
        echo "TIME:$simulation_time"
        return 1
    fi
}

# Function to clean up temporary files
cleanup_temp_files() {
    [[ -f "temp_testbench.v" ]] && rm -f "temp_testbench.v"
    [[ -f "temp_sim" ]] && rm -f "temp_sim"
}

# Function to check if required tools are available
check_dependencies() {
    local missing_deps=()
    
    if ! command -v iverilog >/dev/null 2>&1; then
        missing_deps+=("iverilog")
    fi
    
    if ! command -v vvp >/dev/null 2>&1; then
        missing_deps+=("vvp")
    fi
    
    if ! command -v bc >/dev/null 2>&1; then
        missing_deps+=("bc")
    fi
    
    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required dependencies: ${missing_deps[*]}${RESET}"
        echo "Please install the missing tools and try again."
        exit 1
    fi
}

# Main function
main() {
    local testcases_dir="${1:-../testcases}"
    local total_simulation_time=0
    local passed=0
    local total=0
    
    # Check dependencies
    check_dependencies
    
    # Check if testcases directory exists
    if [[ ! -d "$testcases_dir" ]]; then
        echo "Error: $testcases_dir directory not found"
        exit 1
    fi
    
    # Convert hex files if needed (check if convert_hex.py exists and run it)
    local hex_files_count
    hex_files_count=$(find "$testcases_dir" -name "*.hex" | wc -l)
    
    if [[ $hex_files_count -eq 0 ]] && [[ -f "convert_hex.py" ]]; then
        echo "Converting hex files for iverilog compatibility..."
        if ! python3 convert_hex.py; then
            echo "Error converting hex files"
            exit 1
        fi
    fi
    
    # Find all .hex files and sort them
    local hex_files
    mapfile -t hex_files < <(find "$testcases_dir" -name "*.hex" | sort)
    
    if [[ ${#hex_files[@]} -eq 0 ]]; then
        echo "No .hex files found in $testcases_dir"
        exit 1
    fi
    
    # Process each test case
    for hex_file in "${hex_files[@]}"; do
        local test_name
        test_name=$(basename "$hex_file")
        
        # Skip fence tests
        if [[ "$test_name" =~ ^fence ]]; then
            continue
        fi
        
        # Look for corresponding .data file
        local data_file="${hex_file%.*}.data"
        if [[ ! -f "$data_file" ]]; then
            data_file=""
        fi
        
        total=$((total + 1))
        
        # Run the test and capture simulation time
        local test_output test_result sim_time
        test_output=$(run_test "$hex_file" "$data_file" "$test_name" 2>&1)
        test_result=$?
        
        # Extract simulation time using TIME: delimiter
        sim_time=$(echo "$test_output" | grep "^TIME:" | cut -d: -f2)
        
        # Print output without the TIME line
        echo "$test_output" | grep -v "^TIME:"
        
        # Add to total simulation time (ensure sim_time is numeric)
        if [[ "$sim_time" =~ ^[0-9]*\.?[0-9]+$ ]]; then
            total_simulation_time=$(echo "$total_simulation_time + $sim_time" | bc -l)
        fi
        
        if [[ $test_result -eq 0 ]]; then
            passed=$((passed + 1))
        fi
    done
    
    # Print summary
    echo "Passed $passed/$total test cases"
    printf "Time Estimated for simulation: %.3fs\n" "$total_simulation_time"
    
    # Exit with appropriate code
    if [[ $passed -eq $total ]]; then
        exit 0
    else
        exit 1
    fi
}

# Set up trap to clean up on script exit
trap cleanup_temp_files EXIT

# Run main function
main "$@"
