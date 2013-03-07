#include "Treecode.h"

#if 1
namespace computeForces
{
  static __device__ __forceinline__ int lanemask_lt()
  {
    int mask;
    asm("mov.u32 %0, %lanemask_lt;" : "=r" (mask));
    return mask;
  }
  static __device__ __forceinline__ uint shfl_scan_add_step(uint partial, uint up_offset)
  {
    uint result;
    asm(
        "{.reg .u32 r0;"
        ".reg .pred p;"
        "shfl.up.b32 r0|p, %1, %2, 0;"
        "@p add.u32 r0, r0, %3;"
        "mov.u32 %0, r0;}"
        : "=r"(result) : "r"(partial), "r"(up_offset), "r"(partial));
    return result;
  }
  template <const int levels>
    static __device__ __forceinline__ uint inclusive_scan_warp(const int sum)
    {
      uint mysum = sum;
#pragma unroll
      for(int i = 0; i < levels; ++i)
        mysum = shfl_scan_add_step(mysum, 1 << i);
      return mysum;
    }

  static __device__ __forceinline__ int2 warpIntExclusiveScan(const int value)
  {
    const int sum = inclusive_scan_warp<WARP_SIZE2>(value);
    return make_int2(sum-value, __shfl(sum, WARP_SIZE-1, WARP_SIZE));
  }

  static __device__ __forceinline__ int2 warpBinExclusiveScan(const bool p)
  {
    const unsigned int b = __ballot(p);
    return make_int2(__popc(b & lanemask_lt()), __popc(b));
  }

  /******************* segscan *******/

  static __device__ __forceinline__ int lanemask_le()
  {
    int mask;
    asm("mov.u32 %0, %lanemask_le;" : "=r" (mask));
    return mask;
  }
  static __device__ __forceinline__ int ShflSegScanStepB(
      int partial,
      uint distance,
      uint up_offset)
  {
    asm(
        "{.reg .u32 r0;"
        ".reg .pred p;"
        "shfl.up.b32 r0, %1, %2, 0;"
        "setp.le.u32 p, %2, %3;"
        "@p add.u32 %1, r0, %1;"
        "mov.u32 %0, %1;}"
        : "=r"(partial) : "r"(partial), "r"(up_offset), "r"(distance));
    return partial;
  }
  template<const int SIZE2>
    static __device__ __forceinline__ int inclusive_segscan_warp_step(int value, const int distance)
    {
      for (int i = 0; i < SIZE2; i++)
        value = ShflSegScanStepB(value, distance, 1<<i);
      return value;
    }
  static __device__ __forceinline__ int2 inclusive_segscan_warp(
      const int packed_value, const int carryValue)
  {
    const int  flag = packed_value < 0;
    const int  mask = -flag;
    const int value = (~mask & packed_value) + (mask & (-1-packed_value));

    const int flags = __ballot(flag);

    const int dist_block = __clz(__brev(flags));

    const int laneIdx = threadIdx.x & (WARP_SIZE - 1);
    const int distance = __clz(flags & lanemask_le()) + laneIdx - 31;
    const int val = inclusive_segscan_warp_step<WARP_SIZE2>(value, min(distance, laneIdx));
    return make_int2(val + (carryValue & (-(laneIdx < dist_block))), __shfl(val, WARP_SIZE-1, WARP_SIZE));
  }



#define NCRIT 64
#define CELL_LIST_MEM_PER_WARP (2048*32)

  template<int SHIFT>
    __forceinline__ static __device__ int ringAddr(const int i)
    {
      return (i & ((CELL_LIST_MEM_PER_WARP<<SHIFT) - 1));
    }

  texture<uint4,  1, cudaReadModeElementType> texCellData;
  texture<float4, 1, cudaReadModeElementType> texCellSize;
  texture<float4, 1, cudaReadModeElementType> texCellMonopole;
  texture<float4, 1, cudaReadModeElementType> texCellQuad0;
  texture<float4, 1, cudaReadModeElementType> texCellQuad1;
  texture<float4, 1, cudaReadModeElementType> texPtcl;

  /*******************************/
  /****** Opening criterion ******/
  /*******************************/

  //Improved Barnes Hut criterium
  static __device__ bool split_node_grav_impbh(
      const float4 nodeCOM, 
      const float4 groupCenter, 
      const float4 groupSize)
  {
    //Compute the distance between the group and the cell
    float3 dr = make_float3(
        fabsf(groupCenter.x - nodeCOM.x) - (groupSize.x),
        fabsf(groupCenter.y - nodeCOM.y) - (groupSize.y),
        fabsf(groupCenter.z - nodeCOM.z) - (groupSize.z)
        );

    dr.x += fabsf(dr.x); dr.x *= 0.5f;
    dr.y += fabsf(dr.y); dr.y *= 0.5f;
    dr.z += fabsf(dr.z); dr.z *= 0.5f;

    //Distance squared, no need to do sqrt since opening criteria has been squared
    const float ds2    = dr.x*dr.x + dr.y*dr.y + dr.z*dr.z;

    return (ds2 <= fabsf(nodeCOM.w));
  }

  /******* force due to monopoles *********/

  static __device__ __forceinline__ float4 add_acc(
      float4 acc,  const float4 pos,
      const float massj, const float3 posj,
      const float eps2)
  {
    const float3 dr = make_float3(posj.x - pos.x, posj.y - pos.y, posj.z - pos.z);

    const float r2     = dr.x*dr.x + dr.y*dr.y + dr.z*dr.z + eps2;
    const float rinv   = rsqrtf(r2);
    const float rinv2  = rinv*rinv;
    const float mrinv  = massj * rinv;
    const float mrinv3 = mrinv * rinv2;

    acc.w -= mrinv;
    acc.x += mrinv3 * dr.x;
    acc.y += mrinv3 * dr.y;
    acc.z += mrinv3 * dr.z;

    return acc;
  }


  /******* force due to quadrupoles *********/

  static __device__ __forceinline__ float4 add_acc(
      float4 acc, 
      const float4 pos,
      const float mass, const float3 com,
      const float4 Q0,  const float4 Q1, float eps2) 
  {
    const float3 dr = make_float3(pos.x - com.x, pos.y - com.y, pos.z - com.z);
    const float  r2 = dr.x*dr.x + dr.y*dr.y + dr.z*dr.z + eps2;

    const float rinv  = rsqrtf(r2);
    const float rinv2 = rinv *rinv;
    const float mrinv  =  mass*rinv;
    const float mrinv3 = rinv2*mrinv;
    const float mrinv5 = rinv2*mrinv3; 
    const float mrinv7 = rinv2*mrinv5;   // 16

    float  D0  =  mrinv;
    float  D1  = -mrinv3;
    float  D2  =  mrinv5*(  3.0f);
    float  D3  =  mrinv7*(-15.0f); // 3

    const float q11 = Q0.x;
    const float q22 = Q0.y;
    const float q33 = Q0.z;
    const float q12 = Q1.x;
    const float q13 = Q1.y;
    const float q23 = Q1.z;

    const float  q  = q11 + q22 + q33;
    const float3 qR = make_float3(
        q11*dr.x + q12*dr.y + q13*dr.z,
        q12*dr.x + q22*dr.y + q23*dr.z,
        q13*dr.x + q23*dr.y + q33*dr.z);
    const float qRR = qR.x*dr.x + qR.y*dr.y + qR.z*dr.z;  // 22

    acc.w  -= D0 + 0.5f*(D1*q + D2*qRR);
    float C = D1 + 0.5f*(D2*q + D3*qRR);
    acc.x  += C*dr.x + D2*qR.x;
    acc.y  += C*dr.y + D2*qR.y;
    acc.z  += C*dr.z + D2*qR.z;               // 23

    // total: 16 + 3 + 22 + 23 = 64 flops 

    return acc;
  }


  /******* evalue forces from particles *******/
  template<int NI, bool FULL>
    static __device__ __forceinline__ void directAcc(
        float4 acc_i[NI], 
        const float4 pos_i[NI],
        const int ptclIdx,
        const float eps2)
    {
#if 1
      const float4 M0 = (FULL || ptclIdx >= 0) ? tex1Dfetch(texPtcl, ptclIdx) : make_float4(0.0f, 0.0f, 0.0f, 0.0f);

      //#pragma unroll
      for (int j = 0; j < WARP_SIZE; j++)
      {
        const float4 jM0 = make_float4(__shfl(M0.x, j), __shfl(M0.y, j), __shfl(M0.z, j), __shfl(M0.w,j));
        const float  jmass = jM0.w;
        const float3 jpos  = make_float3(jM0.x, jM0.y, jM0.z);
#pragma unroll
        for (int k = 0; k < NI; k++)
          acc_i[k] = add_acc(acc_i[k], pos_i[k], jmass, jpos, eps2);
      }
#endif
    }

  /******* evalue forces from cells *******/
  template<int NI, bool FULL>
    static __device__ __forceinline__ void approxAcc(
        float4 acc_i[NI], 
        const float4 pos_i[NI],
        const int cellIdx,
        const float eps2)
    {
      float4 M0, Q0, Q1;
      if (FULL || cellIdx >= 0)
      {
        M0 = tex1Dfetch(texCellMonopole, cellIdx);
        Q0 = tex1Dfetch(texCellQuad0,    cellIdx);
        Q1 = tex1Dfetch(texCellQuad1,    cellIdx);
      }
      else
        M0 = Q0 = Q1 = make_float4(0.0f, 0.0f, 0.0f, 0.0f);

      for (int j = 0; j < WARP_SIZE; j++)
      {
        const float4 jM0 = make_float4(__shfl(M0.x, j), __shfl(M0.y, j), __shfl(M0.z, j), __shfl(M0.w,j));
        const float4 jQ0 = make_float4(__shfl(Q0.x, j), __shfl(Q0.y, j), __shfl(Q0.z, j), 0.0f);
        const float4 jQ1 = make_float4(__shfl(Q1.x, j), __shfl(Q1.y, j), __shfl(Q1.z, j), 0.0f);
        const float  jmass = jM0.w;
        const float3 jpos  = make_float3(jM0.x, jM0.y, jM0.z);
#pragma unroll
        for (int k = 0; k < NI; k++)
          acc_i[k] = add_acc(acc_i[k], pos_i[k], jmass, jpos, jQ0, jQ1, eps2);
      }
    }



  template<int SHIFT, int BLOCKDIM2, int NI, bool INTCOUNT>
    static __device__ 
    uint2 treewalk(
        float4 acc_i[NI],
        const float4 _pos_i[NI],
        const float4 groupPos,
        const float eps2,
        const uint2 top_cells,
        int *shmem,
        int *cellList,
        const float4 groupSize)
    {
      const int laneIdx = threadIdx.x & (WARP_SIZE-1);

      /* this helps to unload register pressure */
      float4 pos_i[NI];
#pragma unroll 1
      for (int i = 0; i < NI; i++)
        pos_i[i] = _pos_i[i];

      uint2 interactionCounters = {0}; /* # of approximate and exact force evaluations */

      volatile int *tmpList = shmem;

      int approxCellIdx, directPtclIdx;

      int directCounter = 0;
      int approxCounter = 0;

      for (int root_cell = top_cells.x; root_cell < top_cells.y; root_cell += WARP_SIZE)
        if (root_cell + laneIdx < top_cells.y)
          cellList[ringAddr<SHIFT>(root_cell - top_cells.x + laneIdx)] = root_cell + laneIdx;

      int nCells = top_cells.y - top_cells.x;

      int cellListBlock        = 0;
      int nextLevelCellCounter = 0;

      unsigned int cellListOffset = 0;

      /* process level with n_cells */
#if 1
      while (nCells > 0)
      {
        /* extract cell index from the current level cell list */
        const int cellListIdx = cellListBlock + laneIdx;
        const bool useCell    = cellListIdx < nCells;
        const int cellIdx     = cellList[ringAddr<SHIFT>(cellListOffset + cellListIdx)];
        cellListBlock += min(WARP_SIZE, nCells - cellListBlock);

        /* read from gmem cell's info */
#if 0
        const float4 cellSize = tex1Dfetch(texNodeSize,   cellIdx);
        const float4 cellPos  = tex1Dfetch(texNodeCenter, cellIdx);

#if 1
        const float4 cellCOM  = tex1Dfetch(texMultipole,  cellIdx+cellIdx+cellIdx);

        /* check if cell opening condition is satisfied */
        const float4 cellCOM1 = make_float4(cellCOM.x, cellCOM.y, cellCOM.z, cellPos.w);
        const bool splitCell = split_node_grav_impbh(cellCOM1, groupPos, groupSize);
#else /*added by egaburov, see compute_propertiesD.cu for matching code */
        const bool splitCell = split_node_grav_impbh(cellPos, groupPos, groupSize);
#endif
#else
        const float4   cellSize = tex1Dfetch(texCellSize, cellIdx);
        const CellData cellData = tex1Dfetch(texCellData, cellIdx);

        const bool splitCell = split_node_grav_impbh(cellSize, groupPos, groupSize);
#endif

        /* compute first child, either a cell if node or a particle if leaf */
#if 0
        const int cellData = __float_as_int(cellSize.w);
        const int firstChild =  cellData & 0x0FFFFFFF;
        const int nChildren  = (cellData & 0xF0000000) >> 28;
#endif

        /**********************************************/
        /* split cells that satisfy opening condition */
        /**********************************************/

        const bool isNode = cellData.isNode();

        {
          const int firstChild = cellData.first();
          const int nChildren  = cellData.n();
          bool splitNode  = isNode && splitCell && useCell;

          /* use exclusive scan to compute scatter addresses for each of the child cells */
          const int2 childScatter = warpIntExclusiveScan(nChildren & (-splitNode));

          /* make sure we still have available stack space */
          if (childScatter.y + nCells - cellListBlock > (CELL_LIST_MEM_PER_WARP<<SHIFT))
            return make_uint2(0xFFFFFFFF,0xFFFFFFFF);

#if 1
          /* if so populate next level stack in gmem */
          if (splitNode)
          {
            const int scatterIdx = cellListOffset + nCells + nextLevelCellCounter + childScatter.x;
            for (int i = 0; i < nChildren; i++)
              cellList[ringAddr<SHIFT>(scatterIdx + i)] = firstChild + i;
          }
#else  /* use scan operation to accomplish steps above, doesn't bring performance benefit */
          int nChildren  = childScatter.y;
          int nProcessed = 0;
          int2 scanVal   = {0};
          const int offset = cellListOffset + nCells + nextLevelCellCounter;
          while (nChildren > 0)
          {
            tmpList[laneIdx] = 1;
            if (splitNode && (childScatter.x - nProcessed < WARP_SIZE))
            {
              splitNode = false;
              tmpList[childScatter.x - nProcessed] = -1-firstChild;
            }
            scanVal = inclusive_segscan_warp(tmpList[laneIdx], scanVal.y);
            if (laneIdx < nChildren)
              cellList[ringAddr<SHIFT>(offset + nProcessed + laneIdx)] = scanVal.x;
            nChildren  -= WARP_SIZE;
            nProcessed += WARP_SIZE;
          }
#endif
          nextLevelCellCounter += childScatter.y;  /* increment nextLevelCounter by total # of children */
        }

#if 1
        {
          /***********************************/
          /******       APPROX          ******/
          /***********************************/

          /* see which thread's cell can be used for approximate force calculation */
          const bool approxCell    = !splitCell && useCell;
          const int2 approxScatter = warpBinExclusiveScan(approxCell);

          /* store index of the cell */
          const int scatterIdx = approxCounter + approxScatter.x;
          tmpList[laneIdx] = approxCellIdx;
          if (approxCell && scatterIdx < WARP_SIZE)
            tmpList[scatterIdx] = cellIdx;

          approxCounter += approxScatter.y;

          /* compute approximate forces */
          if (approxCounter >= WARP_SIZE)
          {
            /* evalute cells stored in shmem */
            approxAcc<NI,true>(acc_i, pos_i, tmpList[laneIdx], eps2);

            approxCounter -= WARP_SIZE;
            const int scatterIdx = approxCounter + approxScatter.x - approxScatter.y;
            if (approxCell && scatterIdx >= 0)
              tmpList[scatterIdx] = cellIdx;
            if (INTCOUNT)
              interactionCounters.x += WARP_SIZE*NI;
          }
          approxCellIdx = tmpList[laneIdx];
        }
#endif

#if 1
        {
          /***********************************/
          /******       DIRECT          ******/
          /***********************************/

          const bool isLeaf = !isNode;
          bool isDirect = splitCell && isLeaf && useCell;

          const int firstBody = cellData.pbeg();
          const int     nBody = cellData.pend() - cellData.pbeg();

          const int2 childScatter = warpIntExclusiveScan(nBody & (-isDirect));
          int nParticle  = childScatter.y;
          int nProcessed = 0;
          int2 scanVal   = {0};

          /* conduct segmented scan for all leaves that need to be expanded */
          while (nParticle > 0)
          {
            tmpList[laneIdx] = 1;
            if (isDirect && (childScatter.x - nProcessed < WARP_SIZE))
            {
              isDirect = false;
              tmpList[childScatter.x - nProcessed] = -1-firstBody;
            }
            scanVal = inclusive_segscan_warp(tmpList[laneIdx], scanVal.y);
            const int  ptclIdx = scanVal.x;

            if (nParticle >= WARP_SIZE)
            {
              directAcc<NI,true>(acc_i, pos_i, ptclIdx, eps2);
              nParticle  -= WARP_SIZE;
              nProcessed += WARP_SIZE;
              if (INTCOUNT)
                interactionCounters.y += WARP_SIZE*NI;
            }
            else 
            {
              const int scatterIdx = directCounter + laneIdx;
              tmpList[laneIdx] = directPtclIdx;
              if (scatterIdx < WARP_SIZE)
                tmpList[scatterIdx] = ptclIdx;

              directCounter += nParticle;

              if (directCounter >= WARP_SIZE)
              {
                /* evalute cells stored in shmem */
                directAcc<NI,true>(acc_i, pos_i, tmpList[laneIdx], eps2);
                directCounter -= WARP_SIZE;
                const int scatterIdx = directCounter + laneIdx - nParticle;
                if (scatterIdx >= 0)
                  tmpList[scatterIdx] = ptclIdx;
                if (INTCOUNT)
                  interactionCounters.y += WARP_SIZE*NI;
              }
              directPtclIdx = tmpList[laneIdx];

              nParticle = 0;
            }
          }
        }
#endif

        /* if the current level is processed, schedule the next level */
        if (cellListBlock >= nCells)
        {
          cellListOffset += nCells;
          nCells = nextLevelCellCounter;
          cellListBlock = nextLevelCellCounter = 0;
        }

      }  /* level completed */
#endif

#if 1
      if (approxCounter > 0)
      {
        approxAcc<NI,false>(acc_i, pos_i, laneIdx < approxCounter ? approxCellIdx : -1, eps2);
        if (INTCOUNT)
          interactionCounters.x += WARP_SIZE*NI; //approxCounter * NI;
        approxCounter = 0;
      }
#endif

#if 1
      if (directCounter > 0)
      {
        directAcc<NI,false>(acc_i, pos_i, laneIdx < directCounter ? directPtclIdx : -1, eps2);
        if (INTCOUNT)
          interactionCounters.y += WARP_SIZE*NI; //directCounter * NI;
        directCounter = 0;
      }
#endif

      return interactionCounters;
    }
}
#endif

  template<typename real_t, int NLEAF>
void Treecode<real_t, NLEAF>::computeForces()
{
  printf("Computing forces\n");
}

#include "TreecodeInstances.h"

