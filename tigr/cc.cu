
#include "../shared/timer.hpp"
#include "../shared/tigr_utilities.hpp"
#include "../shared/graph.hpp"
#include "../shared/virtual_graph.hpp"
#include "../shared/globals.hpp"
#include "../shared/argument_parsing.hpp"
#include "../shared/gpu_error_check.cuh"



__global__ void kernel(unsigned int numParts, 
							unsigned int *nodePointer, 
							PartPointer *partNodePointer,
							unsigned int *edgeList, 
							unsigned int *dist, 
							bool *finished,
							bool *label1,
							bool *label2)
{
	int partId = blockDim.x * blockIdx.x + threadIdx.x;

	if(partId < numParts)
	{
		int id = partNodePointer[partId].node;
		int part = partNodePointer[partId].part;

		if(label1[id] == false)
			return;
			
		int sourceWeight = dist[id];

		int thisPointer = nodePointer[id];
		int degree = edgeList[thisPointer];
		

			
		int numParts;
		if(degree % Part_Size == 0)
			numParts = degree / Part_Size ;
		else
			numParts = degree / Part_Size + 1;
		
		int end;
		//int w8;
		//int finalDist;
		int ofs = thisPointer + part + 1;

		for(int i=0; i<Part_Size; i++)
		{
			if(part + i*numParts >= degree)
				break;
			end = ofs + i*numParts;
			//w8 = end + 1;
			// finalDist = sourceWeight + edgeList[w8];
			if(sourceWeight < dist[edgeList[end]])
			{
				//dist[edgeList[end]] = finalDist
				atomicMin(&dist[edgeList[end]] , sourceWeight);
				*finished = false;
				label2[edgeList[end]] = true;
			}
		}		
	}
}


__global__ void clearLabel(bool *label, unsigned int size)
{
	unsigned int id = blockDim.x * blockIdx.x + threadIdx.x;
	if(id < size)
		label[id] = false;
}

int main(int argc, char** argv)
{
	
	ArgumentParser arguments(argc, argv, true, false);
	
	Graph graph(arguments.input, false);
	graph.ReadGraph();
	
	VirtualGraph vGraph(graph);
	
	vGraph.MakeUGraph();
	
	uint num_nodes = graph.num_nodes;
	uint num_edges = graph.num_edges;

	if(arguments.hasDeviceID)
		cudaSetDevice(arguments.deviceID);
		
	cudaFree(0);
	
	unsigned int *dist;
	dist  = new unsigned int[num_nodes];

	bool *label1;
	bool *label2;
	label1 = new bool[num_nodes];
	label2 = new bool[num_nodes];
	
	for(int i=0; i<num_nodes; i++)
	{
		dist[i] = i;
		label1[i] = true;
		label2[i] = false;
	}

	unsigned int *d_nodePointer;
	unsigned int *d_edgeList;
	unsigned int *d_dist;
	PartPointer *d_partNodePointer;
	bool *d_label1;
	bool *d_label2;
	
	bool finished;
	bool *d_finished;

	gpuErrorcheck(cudaMalloc(&d_nodePointer, num_nodes * sizeof(unsigned int)));
	gpuErrorcheck(cudaMalloc(&d_edgeList, (num_edges + num_nodes) * sizeof(unsigned int)));
	gpuErrorcheck(cudaMalloc(&d_dist, num_nodes * sizeof(unsigned int)));
	gpuErrorcheck(cudaMalloc(&d_finished, sizeof(bool)));
	gpuErrorcheck(cudaMalloc(&d_partNodePointer, vGraph.numParts * sizeof(PartPointer)));
	gpuErrorcheck(cudaMalloc(&d_label1, num_nodes * sizeof(bool)));
	gpuErrorcheck(cudaMalloc(&d_label2, num_nodes * sizeof(bool)));	

	gpuErrorcheck(cudaMemcpy(d_nodePointer, vGraph.nodePointer, num_nodes * sizeof(unsigned int), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_edgeList, vGraph.edgeList, (num_edges + num_nodes) * sizeof(unsigned int), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_dist, dist, num_nodes * sizeof(unsigned int), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_partNodePointer, vGraph.partNodePointer, vGraph.numParts * sizeof(PartPointer), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_label1, label1, num_nodes * sizeof(bool), cudaMemcpyHostToDevice));
	gpuErrorcheck(cudaMemcpy(d_label2, label2, num_nodes * sizeof(bool), cudaMemcpyHostToDevice));	

	Timer t;
	t.Start();

	int itr = 0;
	do
	{
		itr++;
		finished = true;
		gpuErrorcheck(cudaMemcpy(d_finished, &finished, sizeof(bool), cudaMemcpyHostToDevice));
		if(itr % 2 == 1)
		{
			kernel<<< vGraph.numParts/512 + 1 , 512 >>>(vGraph.numParts, 
														d_nodePointer,
														d_partNodePointer,
														d_edgeList, 
														d_dist, 
														d_finished,
														d_label1,
														d_label2);
			clearLabel<<< num_nodes/512 + 1 , 512 >>>(d_label1, num_nodes);
		}
		else
		{
			kernel<<< vGraph.numParts/512 + 1 , 512 >>>(vGraph.numParts, 
														d_nodePointer, 
														d_partNodePointer,
														d_edgeList, 
														d_dist, 
														d_finished,
														d_label2,
														d_label1);
			clearLabel<<< num_nodes/512 + 1 , 512 >>>(d_label2, num_nodes);																										
		}

		//getLastCudaError("Kernel execution failed\n");
		gpuErrorcheck( cudaPeekAtLastError() );
		gpuErrorcheck( cudaDeviceSynchronize() );	
		
		//cout << itr << endl;
		
		gpuErrorcheck(cudaMemcpy(&finished, d_finished, sizeof(bool), cudaMemcpyDeviceToHost));

	} while (!(finished));
	
	cout << "Number of iterations = " << itr << endl;

	float runtime = t.Finish();
	cout << "Processing finished in " << runtime << " (ms).\n";
		
	
	gpuErrorcheck(cudaMemcpy(dist, d_dist, num_nodes*sizeof(unsigned int), cudaMemcpyDeviceToHost));

	utilities::PrintResults(dist, 30);

	//int components = 0;
	//for(int i=0; i<num_nodes; i++)
	//	if (dist[i] > 0)
	//	{
	//		cout << "More than one component\n";
	//		cout << i << " " << dist[i] << endl;
	//		break;
	//	}

	//cout << "Number of components = " << components << endl;
	
	if(arguments.hasOutput)
		utilities::SaveResults(arguments.output, dist, num_nodes);
	

	gpuErrorcheck(cudaFree(d_nodePointer));
	gpuErrorcheck(cudaFree(d_edgeList));
	gpuErrorcheck(cudaFree(d_dist));
	gpuErrorcheck(cudaFree(d_finished));
	gpuErrorcheck(cudaFree(d_partNodePointer));
	gpuErrorcheck(cudaFree(d_label1));
	gpuErrorcheck(cudaFree(d_label2));
}
