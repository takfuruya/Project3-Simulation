#include <stdio.h>
#include <cuda.h>
#include <cmath>
#include "glm/glm.hpp"
#include "utilities.h"
#include "kernel.h"

#if SHARED == 1
    #define ACC(x,y,z) sharedMemAcc(x,y,z)
#else
    #define ACC(x,y,z) naiveAcc(x,y,z)
#endif

//GLOBALS
dim3 threadsPerBlock(blockSize);

int numObjects;
const __device__ float planetMass = 3e8;
const __device__ float starMass = 5e10;

const float scene_scale = 2e2; //size of the height map in simulation space

glm::vec4 * dev_pos;
glm::vec3 * dev_vel;
glm::vec3 * dev_acc;

void checkCUDAError(const char *msg, int line = -1)
{
    cudaError_t err = cudaGetLastError();
    if( cudaSuccess != err)
    {
        if( line >= 0 )
        {
            fprintf(stderr, "Line %d: ", line);
        }
        fprintf(stderr, "Cuda error: %s: %s.\n", msg, cudaGetErrorString( err) ); 
        exit(EXIT_FAILURE); 
    }
} 

__host__ __device__
unsigned int hash(unsigned int a){
    a = (a+0x7ed55d16) + (a<<12);
    a = (a^0xc761c23c) ^ (a>>19);
    a = (a+0x165667b1) + (a<<5);
    a = (a+0xd3a2646c) ^ (a<<9);
    a = (a+0xfd7046c5) + (a<<3);
    a = (a^0xb55a4f09) ^ (a>>16);
    return a;
}

//Function that generates static.
__host__ __device__ 
glm::vec3 generateRandomNumberFromThread(float time, int index)
{
    thrust::default_random_engine rng(hash(index*time));
    thrust::uniform_real_distribution<float> u01(0,1);

    return glm::vec3((float) u01(rng), (float) u01(rng), (float) u01(rng));
}

//Generate randomized starting positions for the planets in the XY plane
//Also initialized the masses
__global__
void generateRandomPosArray(int time, int N, glm::vec4 * arr, float scale, float mass)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if(index < N)
    {
        glm::vec3 rand = scale*(generateRandomNumberFromThread(time, index)-0.5f);
        arr[index].x = rand.x;
        arr[index].y = rand.y;
        arr[index].z = 0.0f;//rand.z;
        arr[index].w = mass;
    }
}

//Determine velocity from the distance from the center star. Not super physically accurate because 
//the mass ratio is too close, but it makes for an interesting looking scene
__global__
void generateCircularVelArray(int time, int N, glm::vec3 * arr, glm::vec4 * pos)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if(index < N)
    {
        glm::vec3 R = glm::vec3(pos[index].x, pos[index].y, pos[index].z);
        float r = glm::length(R) + EPSILON;
        float s = sqrt(G*starMass/r);
        glm::vec3 D = glm::normalize(glm::cross(R/r,glm::vec3(0,0,1)));
        arr[index].x = s*D.x;
        arr[index].y = s*D.y;
        arr[index].z = s*D.z;
    }
}

//Generate randomized starting velocities in the XY plane
__global__
void generateRandomVelArray(int time, int N, glm::vec3 * arr, float scale)
{
    int index = (blockIdx.x * blockDim.x) + threadIdx.x;
    if(index < N)
    {
        glm::vec3 rand = scale*(generateRandomNumberFromThread(time, index) - 0.5f);
        arr[index].x = rand.x;
        arr[index].y = rand.y;
        arr[index].z = 0.0;//rand.z;
    }
}

//TODO: Determine force between two bodies
__device__
glm::vec3 calculateAcceleration(glm::vec4 us, glm::vec4 them)
{
    //    G*m_us*m_them
    //F = -------------
    //         r^2
    //
    //    G*m_us*m_them   G*m_them
    //a = ------------- = --------
    //      m_us*r^2        r^2
	//return glm::vec3(0.0f);
    float m = them.w;
	glm::vec3 v(them - us);
	float r = glm::length(v);
	if (r < 0.01f) return glm::vec3(0.0f);
    return glm::normalize(v) * float(G * m / (r * r));
}

//TODO: Core force calc kernel global memory
__device__ 
glm::vec3 naiveAcc(int N, glm::vec4 my_pos, glm::vec4 * their_pos)
{
    glm::vec3 acc(0.0f);
	//acc += glm::vec3(0.0f, 0.0f, 0.01f);
	/*
	for (int i = 0; i < N; ++i)
	{
		acc += calculateAcceleration(my_pos, glm::vec4(their_pos[i].x, their_pos[i].y, their_pos[i].z, planetMass));
	}
	*/
    return acc;
}


//TODO: Core force calc kernel shared memory
__device__ 
glm::vec3 sharedMemAcc(int N, glm::vec4 my_pos, glm::vec4 * their_pos)
{
	extern __shared__ glm::vec4 s[]; // Must hold: blockSize == blockDim.x
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	glm::vec3 acc = calculateAcceleration(my_pos, glm::vec4(0,0,0,starMass));

	int numBlocksForPlanets = N / blockDim.x + 1;
	for ( int i = 0; i < numBlocksForPlanets; ++i )
	{
		// Calculate first & last thread indices for this block.
		int startIdx = i * blockDim.x;		// Inclusive.
		int endIdx = startIdx + blockDim.x; // Not including this.
		if ( endIdx > N ) endIdx = N;

		// Store pos[0 to blockDim.x-1] to shared memory.
		if ( startIdx <= index && index < endIdx ) s[index - startIdx] = their_pos[index - startIdx];
		__syncthreads();

		int numPlanetsInThisBlock = endIdx - startIdx;
		for ( int j = 0; j < numPlanetsInThisBlock; ++j )
		{
			acc += calculateAcceleration(my_pos, glm::vec4(s[j].x, s[j].y, s[j].z, planetMass));
		}
		__syncthreads();
	}
	return acc;
}

//Simple Euler integration scheme
__global__
void updateF(int N, float dt, glm::vec4 * pos, glm::vec3 * vel, glm::vec3 * acc)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    glm::vec4 my_pos;
    glm::vec3 accel;

    if(index < N) my_pos = pos[index];

    accel = ACC(N, my_pos, pos);

    if(index < N) acc[index] = accel;
}


__device__ 
glm::vec2 computeVelocityAlignment(int N, glm::vec4 my_pos, glm::vec4 * their_pos, glm::vec3 * their_vel)
{
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	float x_me = my_pos.x;
	float y_me = my_pos.y;
	glm::vec2 vel(0.0f);
	int numNeighbor = 0;

	for (int i = 0; i < N; ++i)
	{
		if (index == i) continue;
		float delta_x = x_me - their_pos[i].x;
		float delta_y = y_me - their_pos[i].y;
		float dist = sqrt(delta_x * delta_x + delta_y * delta_y);
		if (dist < 10)
		{
			vel.x += their_vel[i].x;
			vel.y += their_vel[i].y;
			numNeighbor ++;
		}
	}

	if (numNeighbor == 0) return vel;

	vel /= (float) numNeighbor;
	return glm::normalize(vel);
}


__device__ 
glm::vec2 computeVelocityCohesion(int N, glm::vec4 my_pos, glm::vec4 * their_pos)
{
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	float x_me = my_pos.x;
	float y_me = my_pos.y;
	glm::vec2 vel(0.0f);
	int numNeighbor = 0;

	for (int i = 0; i < N; ++i)
	{
		if (index == i) continue;
		float x = their_pos[i].x;
		float y = their_pos[i].y;
		float delta_x = x_me - x;
		float delta_y = y_me - y;
		float dist = sqrt(delta_x * delta_x + delta_y * delta_y);
		if (dist < 10)
		{
			vel.x += x;
			vel.y += y;
			numNeighbor ++;
		}
	}

	if (numNeighbor == 0) return vel;

	vel /= (float) numNeighbor;
	vel.x -= x_me;
	vel.y -= y_me;
	return glm::normalize(vel);
}


__device__ 
glm::vec2 computeVelocitySeparation(int N, glm::vec4 my_pos, glm::vec4 * their_pos)
{
	int index = threadIdx.x + (blockIdx.x * blockDim.x);
	float x_me = my_pos.x;
	float y_me = my_pos.y;
	glm::vec2 vel(0.0f);
	int numNeighbor = 0;

	for (int i = 0; i < N; ++i)
	{
		if (index == i) continue;
		float x = their_pos[i].x;
		float y = their_pos[i].y;
		float delta_x = x_me - x;
		float delta_y = y_me - y;
		float dist = sqrt(delta_x * delta_x + delta_y * delta_y);
		if (dist < 10)
		{
			vel.x += x_me - x;
			vel.y += y_me - y;
			numNeighbor ++;
		}
	}

	if (numNeighbor == 0) return vel;

	vel /= (float) numNeighbor;
	return glm::normalize(vel);
}


__global__
void updateV(int N, float dt, glm::vec4 * pos, glm::vec3 * vel, glm::vec3 * acc)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    glm::vec4 my_pos;
    glm::vec3 accel;
	glm::vec2 velocity;

    if(index < N) my_pos = pos[index];

    velocity = computeVelocityAlignment(N, my_pos, pos, vel);
	velocity += computeVelocityCohesion(N, my_pos, pos);
	velocity += computeVelocitySeparation(N, my_pos, pos);

	if (glm::length(velocity) < 0.01) return;

	velocity = glm::normalize(velocity);

	if(index < N) vel[index] = glm::vec3(velocity, 0.0f);
}

__global__
void updateS(int N, float dt, glm::vec4 * pos, glm::vec3 * vel, glm::vec3 * acc)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
	
    if( index < N )
    {
        vel[index]   += acc[index]   * dt;
        pos[index].x += vel[index].x * dt;
        pos[index].y += vel[index].y * dt;
        pos[index].z = atan2(-vel[index].y, -vel[index].x);

		if (pos[index].x > 100.0f) pos[index].x = -99.0f;
		if (pos[index].x < -100.0f) pos[index].x = 99.0f;
		if (pos[index].y > 100.0f) pos[index].y = -99.0f;
		if (pos[index].y < -100.0f) pos[index].y = 99.0f;
		if (pos[index].z > 100.0f) pos[index].z = -99.0f;
		if (pos[index].z < -100.0f) pos[index].z = 99.0f;
    }
}

//Update the vertex buffer object
//(The VBO is where OpenGL looks for the positions for the planets)
__global__
void sendToVBO(int N, glm::vec4 * pos, float * vbo, int width, int height, float s_scale)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);

    float c_scale_w = -2.0f / s_scale;
    float c_scale_h = -2.0f / s_scale;

    if(index<N)
    {
        vbo[4*index+0] = pos[index].x*c_scale_w;
        vbo[4*index+1] = pos[index].y*c_scale_h;
        vbo[4*index+2] = pos[index].z;
        vbo[4*index+3] = 1;
    }
}

//Update the texture pixel buffer object
//(This texture is where openGL pulls the data for the height map)
__global__
void sendToPBO(int N, glm::vec4 * pos, float4 * pbo, int width, int height, float s_scale)
{
    int index = threadIdx.x + (blockIdx.x * blockDim.x);
    int x = index % width;
    int y = index / width;
    float w2 = width / 2.0;
    float h2 = height / 2.0;

    float c_scale_w = width / s_scale;
    float c_scale_h = height / s_scale;

    glm::vec3 color(0.05, 0.15, 0.3);
    glm::vec3 acc = ACC(N, glm::vec4((x-w2)/c_scale_w,(y-h2)/c_scale_h,0,1), pos);

    if(x<width && y<height)
    {
        float mag = sqrt(sqrt(acc.x*acc.x + acc.y*acc.y + acc.z*acc.z));
        // Each thread writes one pixel location in the texture (textel)
        pbo[index].w = (mag < 1.0f) ? mag : 1.0f;
    }
}

/*************************************
 * Wrappers for the __global__ calls *
 *************************************/

//Initialize memory, update some globals
void initCuda(int N)
{
    numObjects = N;
    dim3 fullBlocksPerGrid((int)ceil(float(N)/float(blockSize)));

    cudaMalloc((void**)&dev_pos, N*sizeof(glm::vec4));
    checkCUDAErrorWithLine("Kernel failed!");
    cudaMalloc((void**)&dev_vel, N*sizeof(glm::vec3));
    checkCUDAErrorWithLine("Kernel failed!");
    cudaMalloc((void**)&dev_acc, N*sizeof(glm::vec3));
    checkCUDAErrorWithLine("Kernel failed!");

    generateRandomPosArray<<<fullBlocksPerGrid, blockSize>>>(1, numObjects, dev_pos, scene_scale, planetMass);
    checkCUDAErrorWithLine("Kernel failed!");
    generateCircularVelArray<<<fullBlocksPerGrid, blockSize>>>(2, numObjects, dev_vel, dev_pos);
    checkCUDAErrorWithLine("Kernel failed!");
    cudaThreadSynchronize();
}

void cudaNBodyUpdateWrapper(float dt)
{
    dim3 fullBlocksPerGrid((int)ceil(float(numObjects)/float(blockSize)));
    updateV<<<fullBlocksPerGrid, blockSize, blockSize*sizeof(glm::vec4)>>>(numObjects, dt, dev_pos, dev_vel, dev_acc);
    checkCUDAErrorWithLine("Kernel failed!");
    updateS<<<fullBlocksPerGrid, blockSize>>>(numObjects, dt, dev_pos, dev_vel, dev_acc);
    checkCUDAErrorWithLine("Kernel failed!");
    cudaThreadSynchronize();
}

void cudaUpdateVBO(float * vbodptr, float * dptrpang, int width, int height)
{
    dim3 fullBlocksPerGrid((int)ceil(float(numObjects)/float(blockSize)));
    sendToVBO<<<fullBlocksPerGrid, blockSize>>>(numObjects, dev_pos, vbodptr, width, height, scene_scale);
    cudaThreadSynchronize();
}

void cudaUpdatePBO(float4 * pbodptr, int width, int height)
{
    dim3 fullBlocksPerGrid((int)ceil(float(width*height)/float(blockSize)));
    sendToPBO<<<fullBlocksPerGrid, blockSize, blockSize*sizeof(glm::vec4)>>>(numObjects, dev_pos, pbodptr, width, height, scene_scale);
    cudaThreadSynchronize();
}


