"""
Demo App - OOM Error Generator for AIOps Testing
=================================================

This Lambda function intentionally generates out-of-memory errors
to test the AIOps log analyzer and auto-remediation system.

Features:
- Configurable memory consumption
- Multiple error patterns
- Realistic workload simulation
- Easy to trigger via API/CLI

Author: AWS Community Builder
Version: 1.0.0
Runtime: Python 3.11
"""

import json
import os
import time
import random
from datetime import datetime
from typing import Dict, List, Any

# Configuration
DEFAULT_MEMORY_PATTERN = os.environ.get('MEMORY_PATTERN', 'gradual')
DEFAULT_TARGET_MB = int(os.environ.get('TARGET_MB', '600'))


def lambda_handler(event: Dict[str, Any], context: Any) -> Dict[str, Any]:
    """
    Main Lambda handler - generates OOM errors.
    
    Event options:
    {
        "pattern": "gradual|sudden|leak|spike",
        "target_mb": 600,
        "duration_seconds": 10
    }
    """
    print(f"Demo App started at {datetime.utcnow().isoformat()}")
    print(f"Lambda context: {context.function_name}, Memory: {context.memory_limit_in_mb} MB")
    print(f"Event: {json.dumps(event)}")
    
    # Parse configuration
    pattern = event.get('pattern', DEFAULT_MEMORY_PATTERN)
    target_mb = event.get('target_mb', DEFAULT_TARGET_MB)
    duration = event.get('duration_seconds', 10)
    
    print(f"Configuration: pattern={pattern}, target_mb={target_mb}, duration={duration}s")
    
    # Get current memory usage
    import resource
    initial_memory = get_memory_usage_mb()
    print(f"Initial memory usage: {initial_memory:.2f} MB")
    
    try:
        # Execute the selected pattern
        if pattern == 'gradual':
            result = gradual_memory_growth(target_mb, duration)
        elif pattern == 'sudden':
            result = sudden_memory_spike(target_mb)
        elif pattern == 'leak':
            result = memory_leak_simulation(target_mb, duration)
        elif pattern == 'spike':
            result = repeated_spikes(target_mb, duration)
        else:
            return error_response(f"Unknown pattern: {pattern}")
        
        # This shouldn't be reached if OOM occurs
        return success_response(result)
        
    except MemoryError as e:
        # This is what we want to happen
        print(f"ERROR: Out of memory error occurred: {e}")
        print(f"Memory limit reached: {context.memory_limit_in_mb} MB")
        raise  # Re-raise to ensure Lambda logs the error
    
    except Exception as e:
        print(f"ERROR: Unexpected error: {e}")
        raise


def gradual_memory_growth(target_mb: int, duration_seconds: int) -> Dict:
    """
    Gradually increase memory usage over time.
    Simulates processing increasing amounts of data.
    """
    print(f"Starting gradual memory growth to {target_mb} MB over {duration_seconds}s")
    
    data_chunks = []
    chunk_size = 1024 * 1024  # 1 MB chunks
    interval = duration_seconds / (target_mb / 10)  # Allocate every interval
    
    start_time = time.time()
    iteration = 0
    
    while time.time() - start_time < duration_seconds:
        iteration += 1
        
        # Allocate 10 MB chunk
        chunk = bytearray(chunk_size * 10)
        # Fill with random data to prevent optimization
        for i in range(0, len(chunk), 1024):
            chunk[i] = random.randint(0, 255)
        
        data_chunks.append(chunk)
        
        current_memory = get_memory_usage_mb()
        print(f"Iteration {iteration}: Allocated {len(data_chunks) * 10} MB, Current memory: {current_memory:.2f} MB")
        
        # Check if we've reached target
        if current_memory >= target_mb:
            print(f"Target memory {target_mb} MB reached!")
            # Keep allocating to force OOM
            while True:
                huge_chunk = bytearray(chunk_size * 100)  # 100 MB
                data_chunks.append(huge_chunk)
                print(f"Forcing OOM: Allocated {len(data_chunks) * 10} MB")
        
        time.sleep(interval)
    
    return {
        'pattern': 'gradual',
        'allocated_mb': len(data_chunks) * 10,
        'iterations': iteration
    }


def sudden_memory_spike(target_mb: int) -> Dict:
    """
    Immediately allocate large amount of memory.
    Simulates loading large dataset into memory at once.
    """
    print(f"Starting sudden memory spike: allocating {target_mb} MB immediately")
    
    try:
        # Allocate massive chunk all at once
        chunk_size = 1024 * 1024
        huge_data = bytearray(chunk_size * target_mb)
        
        # Fill with data to prevent optimization
        print("Filling allocated memory with data...")
        for i in range(0, len(huge_data), 10240):
            huge_data[i:i+10] = b'X' * 10
        
        current_memory = get_memory_usage_mb()
        print(f"Allocated {target_mb} MB, Current memory: {current_memory:.2f} MB")
        
        # Try to allocate even more to force OOM
        print("Attempting to allocate additional memory to force OOM...")
        more_data = bytearray(chunk_size * target_mb)
        
        return {
            'pattern': 'sudden',
            'allocated_mb': target_mb * 2
        }
        
    except MemoryError:
        print("SUCCESS: Out of memory error triggered!")
        raise


def memory_leak_simulation(target_mb: int, duration_seconds: int) -> Dict:
    """
    Simulate a memory leak by continuously allocating without releasing.
    Mimics objects not being garbage collected.
    """
    print(f"Starting memory leak simulation to {target_mb} MB over {duration_seconds}s")
    
    # Global list to prevent garbage collection
    leaked_objects = []
    
    start_time = time.time()
    iteration = 0
    
    while time.time() - start_time < duration_seconds:
        iteration += 1
        
        # Create objects that won't be garbage collected
        leaked_data = {
            'id': iteration,
            'data': bytearray(1024 * 1024 * 5),  # 5 MB per object
            'timestamp': time.time(),
            'nested': {
                'more_data': [random.random() for _ in range(10000)]
            }
        }
        
        leaked_objects.append(leaked_data)
        
        current_memory = get_memory_usage_mb()
        print(f"Iteration {iteration}: Leaked objects: {len(leaked_objects)}, Current memory: {current_memory:.2f} MB")
        
        if current_memory >= target_mb:
            print(f"Target memory {target_mb} MB reached via leak!")
            # Continue leaking to force OOM
            while True:
                leaked_objects.append(bytearray(1024 * 1024 * 50))  # 50 MB
                print(f"Forcing OOM via leak: {len(leaked_objects)} objects")
        
        time.sleep(0.5)
    
    return {
        'pattern': 'leak',
        'leaked_objects': len(leaked_objects),
        'iterations': iteration
    }


def repeated_spikes(target_mb: int, duration_seconds: int) -> Dict:
    """
    Create repeated memory spikes.
    Simulates batch processing with memory spikes per batch.
    """
    print(f"Starting repeated memory spikes to {target_mb} MB over {duration_seconds}s")
    
    spike_count = 0
    start_time = time.time()
    
    while time.time() - start_time < duration_seconds:
        spike_count += 1
        
        print(f"Spike {spike_count}: Allocating {target_mb} MB")
        
        # Allocate memory for this spike
        spike_data = bytearray(1024 * 1024 * target_mb)
        
        # Fill with data
        for i in range(0, len(spike_data), 10240):
            spike_data[i] = random.randint(0, 255)
        
        current_memory = get_memory_usage_mb()
        print(f"Spike {spike_count} complete: Current memory: {current_memory:.2f} MB")
        
        # Process the data (keep in memory)
        processed = process_large_dataset(spike_data)
        
        print(f"Processed {len(processed)} items")
        
        # Don't release - let it accumulate
        time.sleep(1)
    
    return {
        'pattern': 'spike',
        'spike_count': spike_count
    }


def process_large_dataset(data: bytearray) -> List[int]:
    """
    Simulate processing large dataset.
    Creates additional memory pressure.
    """
    # Create processed data (adds more memory usage)
    processed = []
    
    # Process in chunks
    chunk_size = 1024
    for i in range(0, len(data), chunk_size):
        chunk = data[i:i+chunk_size]
        # Simulate complex processing
        result = sum(chunk) * len(chunk)
        processed.append(result)
    
    return processed


def get_memory_usage_mb() -> float:
    """
    Get current memory usage in MB.
    """
    import resource
    usage = resource.getrusage(resource.RUSAGE_SELF)
    # maxrss is in kilobytes on Linux, bytes on macOS
    memory_kb = usage.ru_maxrss
    
    # Convert to MB (assuming Linux)
    memory_mb = memory_kb / 1024
    
    return memory_mb


def success_response(result: Dict) -> Dict[str, Any]:
    """Create success response (shouldn't happen if OOM works)."""
    return {
        'statusCode': 200,
        'body': json.dumps({
            'message': 'Demo completed without OOM (unexpected)',
            'result': result,
            'timestamp': datetime.utcnow().isoformat()
        })
    }


def error_response(message: str) -> Dict[str, Any]:
    """Create error response."""
    return {
        'statusCode': 400,
        'body': json.dumps({
            'error': message,
            'timestamp': datetime.utcnow().isoformat()
        })
    }
