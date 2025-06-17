# Network Performance Tuning Scripts

Collection of scripts for optimizing network performance on Linux systems.

## Scripts

### `cpu.sh` - CPU Performance Optimization
**Purpose**: Configures CPU for low-latency workloads  
**Usage**: `sudo ./cpu.sh`

**What it does:**
- Sets performance governor on all CPUs
- Locks CPU frequency (min = max)
- Disables Intel turbo boost
- Disables C-states (C1 and above)
- Disables transparent huge pages
- Disables NUMA balancing
- Disables swap
- Optionally disables SMT

### `irq-pin.sh` - IRQ Pinning and NIC Hardware Tuning
**Purpose**: Configures network interface hardware and pins IRQs to specific CPU cores  
**Usage**: `sudo ./irq-pin.sh <core_range> [interface] [queue_count] [ring_size]`

**Examples:**
```bash
sudo ./irq-pin.sh 9-16                    # Auto-detect interface, 8 cores
sudo ./irq-pin.sh 1-12 eth0               # Specify interface
sudo ./irq-pin.sh 9-16 eno12409np1 8 512  # Custom queue count and ring size
```

**What it does:**
- Maps network interrupts to specific CPU cores (1:1 mapping)
- Sets queue count to match core count
- Configures small ring buffers (default 256)
- Sets 1μs interrupt coalescing
- Disables pause frames and EEE
- Disables RPS/XPS
- Handles RDMA compatibility

### `offloads.sh` - Network Offload Control
**Purpose**: Enable/disable network offloads (GRO/GSO/TSO/LRO)  
**Usage**: `sudo ./offloads.sh <enable|disable|status> [interface]`

**Examples:**
```bash
sudo ./offloads.sh disable        # Auto-detect interface, disable for low latency
sudo ./offloads.sh enable eth0    # Enable for high throughput
sudo ./offloads.sh status         # Check current settings
```

### `busy-poll.sh` - Busy Polling Control
**Purpose**: Configure network busy polling for ultra-low latency  
**Usage**: `sudo ./busy-poll.sh <enable|disable|status> [microseconds]`

**Examples:**
```bash
sudo ./busy-poll.sh enable 50    # Enable with 50μs timeout
sudo ./busy-poll.sh disable      # Disable busy polling
sudo ./busy-poll.sh status       # Check current settings
```

## Flow Control Scripts

### `flow-config/rfs.sh` - RFS Configuration
**Purpose**: Enable/disable RFS (Receive Flow Steering)  
**Usage**: `sudo ./flow-config/rfs.sh <enable|disable>`

**What it does:**
- Configures 64K global flow table
- Sets 4096 entries per queue
- Enables CPU affinity for all CPUs

### `flow-config/rps.sh` - RPS Configuration  
**Purpose**: Enable/disable RPS (Receive Packet Steering)  
**Usage**: `sudo ./flow-config/rps.sh <enable|disable>`

## Common Scripts

### `common/get_interface.sh`
**Purpose**: Auto-detects network interfaces with 10.10.x.x IP addresses  
**Usage**: `./common/get_interface.sh`

## Performance Profiles

### Ultra-Low Latency
```bash
sudo ./cpu.sh
sudo ./irq-pin.sh 9-16
sudo ./offloads.sh disable
sudo ./busy-poll.sh enable 50
```

### High Throughput
```bash
sudo ./cpu.sh
sudo ./irq-pin.sh 9-16
sudo ./offloads.sh enable
sudo ./busy-poll.sh disable
```

### Balanced
```bash
sudo ./cpu.sh
sudo ./irq-pin.sh 9-16
sudo ./offloads.sh disable
sudo ./busy-poll.sh disable
```

## Requirements

- Root privileges (use sudo)
- ethtool
- Linux 4.4+ kernel