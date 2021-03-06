CUDA Simulation (N-Body &amp; Flocking)
=======================================

N-Body
------
![25](Part1/resources/25.png)

### CPU vs GPU
Is GPU really faster? I implemented the same program on both CPU and GPU to compare their performance.
GPU was indeed faster.
It can also be seen that the CPU exhibits the characteristics of O(n<sup>2</sup>) time complexity for force calculation.
In addition, CPU is faster at 10 planets. This can be explained by kernel launch overhead being significant.
![Performance Comparison Results](Part1/resources/Performance Comparison.png)  
<p align="center"><img src="Part1/resources/Performance Comparison Scaled.png" /></p>
<sub><sup>Note 1: Above were calculated based on time taken to compute the acceleration, velocity, and position of each planet (i.e. does not include rendering and CUDA-OpenGL interop).</sup></sub>  
<sub><sup>Note 2: CPU is implemented in a naive approach (single threaded, double for-loop).</sup></sub>  
<sub><sup>Note 3: GPU is implemented in a naive approach (no shared memory, coalesced memory transaction, etc.).</sup></sub>

### Galaxy
![Galaxy](Part1/resources/3200_2.png)
&#8593; 3200 planets after 1000 frames.

Flocking
--------
![Flocking](Part1/resources/Flocking.png)  

<sub><sup>Note: This was for a class at UPenn: CIS565 Project 3 Fall 2013 (Due 10/22/2013)</sup></sub>

