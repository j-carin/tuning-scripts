"""
kernel-config — configure kernel boot parameters for low-latency work
Usage: uv run <enable|disable> [core_range]
"""

import sys
import os
import subprocess
import curses
from typing import Dict, List, Tuple

KERNEL_PARAMS = {
    "isolcpus": {
        "param": "isolcpus={CORES}",
        "desc": "Isolate CPUs from scheduler",
        "info": "Essential for RT workloads. Prevents the scheduler from placing tasks on isolated cores."
    },
    "nohz_full": {
        "param": "nohz_full={CORES}",
        "desc": "Disable timer ticks on isolated cores",
        "info": "Reduces interrupts by disabling periodic timer ticks on specified cores."
    },
    "rcu_nocbs": {
        "param": "rcu_nocbs={CORES}",
        "desc": "Move RCU callbacks off isolated cores",
        "info": "Reduces CPU overhead by moving RCU grace period handling to other cores."
    },
    "housekeeping": {
        "param": "housekeeping=cpus:0",
        "desc": "Keep housekeeping tasks on CPU 0",
        "info": "Recommended with isolation. Confines kernel housekeeping to specific cores."
    },
    "intel_pstate": {
        "param": "intel_pstate=disable",
        "desc": "Disable Intel P-State driver",
        "info": "More predictable performance. Prevents CPU frequency scaling by Intel driver."
    },
    "nosmt": {
        "param": "nosmt",
        "desc": "Disable hyperthreading",
        "info": "Better cache locality. Disables simultaneous multithreading for more predictable performance."
    },
    "intel_idle_cstate": {
        "param": "intel_idle.max_cstate=0",
        "desc": "Disable Intel idle C-states",
        "info": "Lowest latency. Prevents CPU from entering power-saving sleep states."
    },
    "processor_cstate": {
        "param": "processor.max_cstate=0",
        "desc": "Disable processor C-states",
        "info": "Prevents CPU sleep. Keeps processor in highest performance state at all times."
    },
    "mitigations": {
        "param": "mitigations=off",
        "desc": "Disable security mitigations",
        "info": "Maximum performance (less secure). Disables Spectre/Meltdown mitigations for speed."
    },
    "intel_iommu": {
        "param": "intel_iommu=off",
        "desc": "Disable Intel IOMMU",
        "info": "Reduces DMA overhead. May improve performance but reduces security isolation."
    },
    "iommu": {
        "param": "iommu=off",
        "desc": "Disable generic IOMMU",
        "info": "Reduces DMA overhead. Complements intel_iommu=off for maximum DMA performance."
    }
}

PARAM_ORDER = [
    "isolcpus", "nohz_full", "rcu_nocbs", "housekeeping", "intel_pstate", 
    "nosmt", "intel_idle_cstate", "processor_cstate", "mitigations", 
    "intel_iommu", "iommu"
]

class KernelConfigMenu:
    def __init__(self, core_range: str):
        self.core_range = core_range
        self.selected = {key: True for key in PARAM_ORDER}
        self.current = 0
        self.offset = 0
        
    def draw_menu(self, stdscr):
        height, width = stdscr.getmaxyx()
        menu_height = height - 6  # Leave space for header, footer, and info
        
        # Clear screen
        stdscr.clear()
        
        # Header
        stdscr.addstr(0, 2, f"Kernel Configuration - Core Range: {self.core_range}", curses.A_BOLD)
        stdscr.addstr(1, 2, "Use ↑↓ to navigate, SPACE to toggle, ENTER to apply, q to quit")
        stdscr.addstr(2, 0, "─" * (width - 1))
        
        # Calculate visible range
        visible_start = self.offset
        visible_end = min(len(PARAM_ORDER) + 1, visible_start + menu_height)
        
        # Draw menu items
        for i in range(visible_start, visible_end):
            y_pos = 3 + (i - visible_start)
            
            if i < len(PARAM_ORDER):
                key = PARAM_ORDER[i]
                param_info = KERNEL_PARAMS[key]
                
                # Checkbox
                checkbox = "[X]" if self.selected[key] else "[ ]"
                
                # Highlight current item
                attr = curses.A_REVERSE if i == self.current else curses.A_NORMAL
                
                # Format line
                line = f"  {checkbox} {key:<18} {param_info['desc']}"
                line = line[:width-2]  # Truncate if too long
                
                stdscr.addstr(y_pos, 0, line, attr)
            else:
                # Apply option
                attr = curses.A_REVERSE if i == self.current else curses.A_NORMAL
                stdscr.addstr(y_pos, 0, "  >> Apply Configuration", attr | curses.A_BOLD)
        
        # Info panel at bottom
        info_y = height - 3
        stdscr.addstr(info_y, 0, "─" * (width - 1))
        
        if self.current < len(PARAM_ORDER):
            key = PARAM_ORDER[self.current]
            param_info = KERNEL_PARAMS[key]
            info_text = f"{param_info['param'].replace('{CORES}', self.core_range)}: {param_info['info']}"
            # Wrap text if too long
            if len(info_text) > width - 4:
                info_text = info_text[:width-7] + "..."
            stdscr.addstr(info_y + 1, 2, info_text)
        else:
            stdscr.addstr(info_y + 1, 2, "Apply the selected kernel parameters to GRUB configuration")
        
        stdscr.refresh()
    
    def handle_input(self, stdscr):
        while True:
            self.draw_menu(stdscr)
            key = stdscr.getch()
            
            if key == curses.KEY_UP:
                self.current = max(0, self.current - 1)
                # Adjust offset for scrolling
                if self.current < self.offset:
                    self.offset = self.current
                    
            elif key == curses.KEY_DOWN:
                self.current = min(len(PARAM_ORDER), self.current + 1)
                # Adjust offset for scrolling
                height, _ = stdscr.getmaxyx()
                menu_height = height - 6
                if self.current >= self.offset + menu_height:
                    self.offset = self.current - menu_height + 1
                    
            elif key == ord(' ') and self.current < len(PARAM_ORDER):
                # Toggle selection
                param_key = PARAM_ORDER[self.current]
                self.selected[param_key] = not self.selected[param_key]
                
            elif key == ord('\n') or key == curses.KEY_ENTER:
                if self.current == len(PARAM_ORDER):
                    # Apply configuration
                    return True
                    
            elif key == ord('q') or key == ord('Q'):
                return False
    
    def get_selected_params(self) -> str:
        params = []
        for key in PARAM_ORDER:
            if self.selected[key]:
                param = KERNEL_PARAMS[key]["param"].replace("{CORES}", self.core_range)
                params.append(param)
        return " ".join(params)

def check_root():
    if os.geteuid() != 0:
        print("Error: This script must be run as root (use sudo)")
        sys.exit(1)

def update_grub_config(params: str):
    grub_config = "/etc/default/grub"
    
    try:
        # Backup original file
        subprocess.run(["cp", grub_config, f"{grub_config}.backup"], check=True)
        
        # Read current config
        with open(grub_config, 'r') as f:
            lines = f.readlines()
        
        # Update GRUB_CMDLINE_LINUX_DEFAULT
        updated = False
        for i, line in enumerate(lines):
            if line.startswith("GRUB_CMDLINE_LINUX_DEFAULT="):
                lines[i] = f'GRUB_CMDLINE_LINUX_DEFAULT="{params}"\n'
                updated = True
                break
        
        if not updated:
            lines.append(f'GRUB_CMDLINE_LINUX_DEFAULT="{params}"\n')
        
        # Write updated config
        with open(grub_config, 'w') as f:
            f.writelines(lines)
        
        # Update grub
        subprocess.run(["update-grub"], check=True)
        
        return True
    except Exception as e:
        print(f"Error updating GRUB configuration: {e}")
        return False

def clear_grub_config():
    grub_config = "/etc/default/grub"
    
    try:
        # Read current config
        with open(grub_config, 'r') as f:
            lines = f.readlines()
        
        # Clear GRUB_CMDLINE_LINUX_DEFAULT
        for i, line in enumerate(lines):
            if line.startswith("GRUB_CMDLINE_LINUX_DEFAULT="):
                lines[i] = 'GRUB_CMDLINE_LINUX_DEFAULT=""\n'
                break
        
        # Write updated config
        with open(grub_config, 'w') as f:
            f.writelines(lines)
        
        # Update grub
        subprocess.run(["update-grub"], check=True)
        
        return True
    except Exception as e:
        print(f"Error clearing GRUB configuration: {e}")
        return False

def main():
    if len(sys.argv) < 2:
        print("Usage: uv run <enable|disable> [core_range]")
        sys.exit(1)
    
    check_root()
    
    action = sys.argv[1]
    core_range = sys.argv[2] if len(sys.argv) > 2 else "1-12"
    
    if action == "enable":
        menu = KernelConfigMenu(core_range)
        
        try:
            apply_config = curses.wrapper(menu.handle_input)
            
            if apply_config:
                selected_params = menu.get_selected_params()
                
                if selected_params:
                    print(f"Applying parameters: {selected_params}")
                    if update_grub_config(selected_params):
                        print("✓ Selected kernel parameters installed. Reboot to apply.")
                    else:
                        print("✗ Failed to update kernel parameters.")
                        sys.exit(1)
                else:
                    print("No parameters selected. Exiting.")
            else:
                print("Configuration cancelled.")
                
        except KeyboardInterrupt:
            print("\nConfiguration cancelled.")
            sys.exit(0)
            
    elif action == "disable":
        if clear_grub_config():
            print("✓ Kernel parameters cleared. Reboot to revert.")
        else:
            print("✗ Failed to clear kernel parameters.")
            sys.exit(1)
    else:
        print(f"Error: invalid action '{action}' (use enable|disable)")
        sys.exit(1)


if __name__ == "__main__":
    main()
