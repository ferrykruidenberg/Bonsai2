#include "Treecode.h"

namespace computeForces
{
  template<typename real_t>
    static __device__ __forceinline__ 
    void addBoxSize(typename vec<3,real_t>::type &_rmin, typename vec<3,real_t>::type &_rmax, const Position<real_t> pos)
    {
      typename vec<3,real_t>::type rmin = {pos.x, pos.y, pos.z};
      typename vec<3,real_t>::type rmax = rmin;

#pragma unroll
      for (int i = WARP_SIZE2-1; i >= 0; i--)
      {
        rmin.x = min(rmin.x, __shfl_xor(rmin.x, 1<<i, WARP_SIZE));
        rmax.x = max(rmax.x, __shfl_xor(rmax.x, 1<<i, WARP_SIZE));

        rmin.y = min(rmin.y, __shfl_xor(rmin.y, 1<<i, WARP_SIZE));
        rmax.y = max(rmax.y, __shfl_xor(rmax.y, 1<<i, WARP_SIZE));

        rmin.z = min(rmin.z, __shfl_xor(rmin.z, 1<<i, WARP_SIZE));
        rmax.z = max(rmax.z, __shfl_xor(rmax.z, 1<<i, WARP_SIZE));
      }

      _rmin.x = min(_rmin.x, rmin.x);
      _rmin.y = min(_rmin.y, rmin.y);
      _rmin.z = min(_rmin.z, rmin.z);

      _rmax.x = max(_rmax.x, rmax.x);
      _rmax.y = max(_rmax.y, rmax.y);
      _rmax.z = max(_rmax.z, rmax.z);
    }

  /************ scan **********/
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

  /************** binary scan ***********/
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
  
  texture<uint4,  1, cudaReadModeElementType> texCellData;
  texture<float4, 1, cudaReadModeElementType> texCellSize;
  texture<float4, 1, cudaReadModeElementType> texCellMonopole;
  texture<float4, 1, cudaReadModeElementType> texCellQuad0;
  texture<float2, 1, cudaReadModeElementType> texCellQuad1;
  texture<float4, 1, cudaReadModeElementType> texPtcl;

  template<int SHIFT>
    __forceinline__ static __device__ int ringAddr(const int i)
    {
      return (i & ((CELL_LIST_MEM_PER_WARP<<SHIFT) - 1));
    }


  /*******************************/
  /****** Opening criterion ******/
  /*******************************/

  //Improved Barnes Hut criterium
  static __device__ bool split_node_grav_impbh(
      const float4 cellSize, 
      const float3 groupCenter, 
      const float3 groupSize)
  {
    //Compute the distance between the group and the cell
    float3 dr = make_float3(
        fabsf(groupCenter.x - cellSize.x) - (groupSize.x),
        fabsf(groupCenter.y - cellSize.y) - (groupSize.y),
        fabsf(groupCenter.z - cellSize.z) - (groupSize.z)
        );

    dr.x += fabsf(dr.x); dr.x *= 0.5f;
    dr.y += fabsf(dr.y); dr.y *= 0.5f;
    dr.z += fabsf(dr.z); dr.z *= 0.5f;

    //Distance squared, no need to do sqrt since opening criteria has been squared
    const float ds2    = dr.x*dr.x + dr.y*dr.y + dr.z*dr.z;

    return (ds2 <= fabsf(cellSize.w));
  }

  /******* force due to monopoles *********/

  static __device__ __forceinline__ float4 add_acc(
      float4 acc,  const float3 pos,
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
      const float3 pos,
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
        const float3 pos_i[NI],
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
        const float3 pos_i[NI],
        const int cellIdx,
        const float eps2)
    {
      float4 M0, Q0, Q1;
      if (FULL || cellIdx >= 0)
      {
        M0 = tex1Dfetch(texCellMonopole, cellIdx);
        const Quadrupole<float> Q(tex1Dfetch(texCellQuad0,cellIdx), tex1Dfetch(texCellQuad1,cellIdx));
        Q0 = make_float4(Q.xx(), Q.yy(), Q.zz(), 0.0f);
        Q1 = make_float4(Q.xy(), Q.xz(), Q.yz(), 0.0f);
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
    uint2 treewalk_warp(
        float4 acc_i[NI],
        const float3 _pos_i[NI],
        const float3 groupCentre,
        const float3 groupSize,
        const float eps2,
        const int2 top_cells,
        int *shmem,
        int *cellList)
    {
      const int laneIdx = threadIdx.x & (WARP_SIZE-1);

      /* this helps to unload register pressure */
      float3 pos_i[NI];
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
        const float4   cellSize = tex1Dfetch(texCellSize, cellIdx);
        const CellData cellData = tex1Dfetch(texCellData, cellIdx);

#if 0
        if (blockIdx.x == 0 && threadIdx.x < 32)
        {
          printf("cellData.first() = %d    cellData.n()= %d \n",
              cellData.first(),
              cellData.n()); 
          assert(0);
        }
#endif

        const bool splitCell = split_node_grav_impbh(cellSize, groupCentre, groupSize);

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

  __device__ unsigned int retired_groupCount = 0;

  template<int NTHREAD2, bool INTCOUNT>
    __launch_bounds__(1<<NTHREAD2, 1024/(1<<NTHREAD2))
    static __global__ 
    void treewalk(
        const int nPtcl,
        const int nGroups,
        const GroupData *groupList,
        const float eps2,
        const int starting_level,
        const Particle4<float> *ptclPos,
        __out Particle4<float> *acc,
        __out int2   *interactions,
        __out int    *gmem_pool)
    {
      typedef float real_t;
      typedef typename vec<3,real_t>::type real3_t;
      typedef typename vec<4,real_t>::type real4_t;

      const int NTHREAD = 1<<NTHREAD2;
      const int shMemSize = NTHREAD;
      __shared__ int shmem_pool[shMemSize];

      const int laneIdx = threadIdx.x & (WARP_SIZE-1);
      const int warpIdx = threadIdx.x >> WARP_SIZE2;

      const int NWARP2 = NTHREAD2 - WARP_SIZE2;
      const int sh_offs = (shMemSize >> NWARP2) * warpIdx;
      int *shmem = shmem_pool + sh_offs;
      int *gmem  =  gmem_pool + CELL_LIST_MEM_PER_WARP*((1<<NWARP2)*blockIdx.x + warpIdx);

      const int2 top_cells = make_int2(0,8);

      while(1)
      {
        int groupIdx = 0;
        if (laneIdx == 0)
          groupIdx = atomicAdd(&retired_groupCount, 1);
        groupIdx = __shfl(groupIdx, 0, WARP_SIZE);

        if (groupIdx >= nGroups) return;

        const GroupData group = groupList[groupIdx];
        const int pbeg = group.pbeg();
        const int np   = group.np();

        assert(np > 0);
        assert(np <= WARP_SIZE);

        const int NI = 1;
        real3_t iPos[NI];

#pragma unroll
        for (int i = 0; i < NI; i++)
        {
          const Particle4<real_t> ptcl = ptclPos[min(pbeg + i*WARP_SIZE+laneIdx, pbeg+np-1)];
          iPos[i] = make_float3(ptcl.x(), ptcl.y(), ptcl.z());
        }

        real3_t rmin = {iPos[0].x, iPos[0].y, iPos[0].z};
        real3_t rmax = rmin;

#pragma unroll
        for (int i = 0; i < NI; i++) 
          addBoxSize(rmin, rmax, Position<real_t>(iPos[i].x, iPos[i].y, iPos[i].z));

        rmin.x = __shfl(rmin.x,0);
        rmin.y = __shfl(rmin.y,0);
        rmin.z = __shfl(rmin.z,0);
        rmax.x = __shfl(rmax.x,0);
        rmax.y = __shfl(rmax.y,0);
        rmax.z = __shfl(rmax.z,0);

#if 0
        if (laneIdx == 0)
          printf("groupIdx= %d: rmin= %g %g %g  rmax= %g %g %g \n",
              groupIdx, rmin.x, rmin.y, rmin.z, rmax.x, rmax.y, rmax.z);
#endif

        const real_t half = static_cast<real_t>(0.5f);
        const real3_t cvec = {half*(rmax.x+rmin.x), half*(rmax.y+rmin.y), half*(rmax.z+rmin.z)};
        const real3_t hvec = {half*(rmax.x-rmin.x), half*(rmax.y-rmin.y), half*(rmax.z-rmin.z)};

        const int SHIFT = 0;

        real4_t iAcc[NI];

#if 1
        const uint2 counters = treewalk_warp<SHIFT,NTHREAD2,NI,INTCOUNT>
          (iAcc, iPos, cvec, hvec, eps2, top_cells, shmem, gmem);
#else
        uint2 counters = {1,1};
        iAcc[0].x = cvec.x;
        iAcc[0].y = cvec.y;
        iAcc[0].z = cvec.z;
#endif

        assert(!(counters.x == 0xFFFFFFFF && counters.y == 0xFFFFFFFF));

        const int pidx = pbeg + laneIdx;
        if (pidx < nPtcl)
        {
          acc         [pidx] = iAcc[0];
          if (INTCOUNT)
            interactions[pidx] = make_int2(counters.x, counters.y);
        }
      }
    }
}

  template<typename Tex, typename T>
void bindTexture(Tex &tex, const T *ptr, const int size)
{
  tex.addressMode[0] = cudaAddressModeWrap;
  tex.addressMode[1] = cudaAddressModeWrap;
  tex.filterMode     = cudaFilterModePoint;
  tex.normalized     = false;
  CUDA_SAFE_CALL(cudaBindTexture(0, tex, ptr, size*sizeof(T)));
}

  template<typename Tex>
void unbindTexture(Tex &tex)
{
  CUDA_SAFE_CALL(cudaUnbindTexture(tex));
}

  template<typename real_t, int NLEAF>
double2 Treecode<real_t, NLEAF>::computeForces(const bool INTCOUNT)
{
  assert(INTCOUNT);

  bindTexture(computeForces::texCellData,     (uint4* )d_cellDataList.ptr, nCells);
  bindTexture(computeForces::texCellSize,     d_cellSize.ptr,     nCells);
  bindTexture(computeForces::texCellMonopole, d_cellMonopole.ptr, nCells);
  bindTexture(computeForces::texCellQuad0,    d_cellQuad0.ptr,    nCells);
  bindTexture(computeForces::texCellQuad1,    d_cellQuad1.ptr,    nCells);
  bindTexture(computeForces::texPtcl,         d_ptclPos.ptr,      nCells);

  cuda_mem<int2> d_interactions;
  if (INTCOUNT)
    d_interactions.alloc(nPtcl);


  const int NTHREAD2 = 7;
  cuda_mem<int> d_gmem_pool;

  const int nblock = 16*13;
  const int NGROUP2 = 5;
  d_gmem_pool.alloc(CELL_LIST_MEM_PER_WARP*nblock*(1<<(NTHREAD2-NGROUP2)));

  const int starting_level = 1;
  int value = 0;
  cudaDeviceSynchronize();
  const double t0 = rtc();
  CUDA_SAFE_CALL(cudaMemcpyToSymbol(computeForces::retired_groupCount, &value, sizeof(int)));
  computeForces::treewalk<NTHREAD2,true><<<nblock,1<<NTHREAD2>>>(
      nPtcl, nGroups, d_groupList, eps2, starting_level,
      d_ptclPos_tmp, d_ptclPos_tmp,
      d_interactions, d_gmem_pool);
  kernelSuccess("treewalk");
  const double t1 = rtc();
  const double dt = t1 - t0;
  fprintf(stderr, " treewalk done in %g sec : %g Mptcl/sec\n",  dt, nPtcl/1e6/dt);

  double2 interactions;
  if (INTCOUNT)
  {
    std::vector<int2> h_interactions(nPtcl);
    d_interactions.d2h(&h_interactions[0]);
    for (int i = 0; i < nPtcl; i++)
    {
      interactions.x += (double)h_interactions[i].x;
      interactions.y += (double)h_interactions[i].y;
    };
  }

  unbindTexture(computeForces::texPtcl);
  unbindTexture(computeForces::texCellQuad1);
  unbindTexture(computeForces::texCellQuad0);
  unbindTexture(computeForces::texCellMonopole);
  unbindTexture(computeForces::texCellSize);
  unbindTexture(computeForces::texCellData);

  return interactions;
}

#include "TreecodeInstances.h"

