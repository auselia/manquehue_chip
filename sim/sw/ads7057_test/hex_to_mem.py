import sys
import argparse

def translate_hex(input_file, output_file, base_address):
    try:
        with open(input_file, 'r') as infile, open(output_file, 'w') as outfile:
            # Write the standard Verilog readmemh header
            outfile.write("/* Contents of Memory Array starting from address 0. */\n")
            
            for line in infile:
                line = line.strip()
                if not line:
                    continue
                
                # Check if the line is an address marker
                if line.startswith('@'):
                    orig_addr = int(line[1:], 16)
                    
                    # Only translate addresses that fall within the QSPI base range
                    if orig_addr >= base_address:
                        new_addr = orig_addr - base_address
                        # Format back to an 8-character uppercase hex string
                        outfile.write(f"@{new_addr:08X}\n")
                    else:
                        print(f"Warning: Address @{orig_addr:08X} is below the base address. Passing through unmodified.")
                        outfile.write(f"@{orig_addr:08X}\n")
                else:
                    # Pass data lines through exactly as they are
                    outfile.write(line + "\n")
                    
        print(f"Success! Translated '{input_file}' to '{output_file}'.")

    except FileNotFoundError:
        print(f"Error: Could not find the input file '{input_file}'.")
    except Exception as e:
        print(f"An unexpected error occurred: {e}")

if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Translate absolute .hex addresses to 0-based MEM.TXT for Verilog $readmemh.")
    parser.add_argument("input_hex", help="Path to the compiled input .hex file")
    parser.add_argument("--output", default="MEM.TXT", help="Path to the output file (default: MEM.TXT)")
    parser.add_argument("--base", type=lambda x: int(x, 16), default="20000000", help="Base address in hex to subtract (default: 21000000)")
    
    args = parser.parse_args()
    
    translate_hex(args.input_hex, args.output, args.base)