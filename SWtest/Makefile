CXX = g++
CC  = gcc
LD  = g++
F90  = ifort

.SUFFIXES: .o .cpp .ptx .cu

CUDA_TK  = /usr/local/cuda

OFLAGS = -O3 -g -Wall 
CXXFLAGS =   $(OFLAGS)  -Wstrict-aliasing=2 


NVCC = $(CUDA_TK)/bin/nvcc  
NVCCFLAGS  =  -Xptxas=-v  -arch=sm_35 -maxrregcount=32 -DPLUMMER
NVCCLDFLAGS = -lcudadevrt -arch=sm_35  

INCLUDEPATH = ./include
CXXFLAGS  += -I$(INCLUDEPATH)
NVCCFLAGS += -I$(INCLUDEPATH)

CUDASRCPATH = ./
CUDASRC = treebuild.cu

SRCPATH = ./
SRC =


OBJ = $(SRC:%.cpp=%.o)
CUOBJ = $(CUDASRC:%.cu=%.o)

PROG = treecode

all:	  $(OBJ)  $(CUOBJ) $(PROG)
kernels:  $(CUDAOBJ)

$(PROG): $(OBJ) $(CUOBJ)
	$(NVCC)  $^ -o $@  $(NVCCLDFLAGS)

%.o: $(SRCPATH)/%.cpp
	$(CXX) $(CXXFLAGS) -c $< -o $@

%.o:  $(CUDASRCPATH)/%.cu
	$(NVCC) $(NVCCFLAGS) -rdc=true -c $< -o $@

makeGroups.o: $(CUDASRCPATH)/makeGroups.cu
	$(NVCC) $(NVCCFLAGS) -c $< -o $@


clean:
	/bin/rm -rf *.o  $(PROG) *.a *.cu_o 

clean_all:
	/bin/rm -rf *.o  $(PROG) *.a *.cu_o  *~








