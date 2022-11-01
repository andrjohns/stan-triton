FROM rocker/r-ver:4.2.1

# Defined only while building
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install intel-mkl-full nvidia-opencl-icd \
                                      clinfo sudo nvidia-cuda-toolkit -y

# Specify that the MKL should provide the Matrix algebra libraries for the system
RUN update-alternatives --install /usr/lib/x86_64-linux-gnu/libblas.so.3 \
                                  libblas.so.3-x86_64-linux-gnu \
                                  /usr/lib/x86_64-linux-gnu/libmkl_rt.so 150

RUN update-alternatives --install /usr/lib/x86_64-linux-gnu/liblapack.so.3 \
                                  liblapack.so.3-x86_64-linux-gnu \
                                  /usr/lib/x86_64-linux-gnu/libmkl_rt.so 150

RUN adduser --disabled-password --gecos '' stan_triton
RUN adduser stan_triton sudo
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

ENV MKL_INTERFACE_LAYER GNU,LP64
ENV MKL_THREADING_LAYER GNU
ENV R_LIBS_USER /home/stan_triton/R/library
ENV R_MAKEVARS_USER /home/stan_triton/.R/Makevars
ENV CMDSTAN /home/stan_triton/.cmdstan/cmdstan-2.30.1

USER stan_triton
WORKDIR /home/stan_triton

# Create local library for packages and make sure R is aware we're linking to the TBB
# Local library is prepended to the R_LIBS_USER env so that we can specify external
# libraries when calling the image
RUN mkdir -p R/library

RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  install.packages(c('multiverse','remotes','rstan','projpred','brms','devtools')) \
"

RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  remotes::install_github('stan-dev/cmdstanr', dependencies = TRUE) \
"

RUN Rscript -e " \
  cmdstanr::install_cmdstan(cores = parallel::detectCores()); \
  cmdstanr::cmdstan_make_local(cpp_options = list( \
    'CXXFLAGS += -O3 -march=native -mtune=native -DEIGEN_USE_MKL_ALL -I/usr/include/mkl \
                  -Wno-enum-compare -Wno-deprecated-declarations -Wno-ignored-attributes \
                  -DMKL_ILP64 -m64', \
    'LDFLAGS += -L/usr/lib/x86_64-linux-gnu/intel64 -Wl,--no-as-needed--no-as-needed \
                -lmkl_intel_ilp64 -lmkl_gnu_thread -lmkl_core -lgomp -lpthread -lm -ldl', \
    'TBB_INC=/usr/include', \
    'TBB_LIB=/usr/lib/x86_64-linux-gnu', \
    'TBB_INTERFACE_NEW=true', \
    'STAN_THREADS=true', \
    'STANCFLAGS=\'--O1\''\
  )); \
  cmdstanr::rebuild_cmdstan(cores = parallel::detectCores()) \
"

RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  remotes::install_git('https://github.com/stan-dev/rstan', \
                        subdir = 'StanHeaders', ref = 'experimental'); \
  remotes::install_git('https://github.com/stan-dev/rstan', \
                        subdir = 'rstan/rstan', ref = 'experimental') \
"

# Create R Makevars file with compiler optimisations and linker flags for
# the Intel MKL and TBB libraries
RUN mkdir .R
RUN echo " \
  CXXFLAGS += -O3 -march=native -mtune=native -DMKL_ILP64 -m64 -DEIGEN_USE_MKL_ALL -I/usr/include/mkl \
              -Wno-enum-compare -Wno-deprecated-declarations -Wno-ignored-attributes \n \
  CXX14FLAGS += -O3 -march=native -mtune=native -DMKL_ILP64 -m64 -DEIGEN_USE_MKL_ALL -I/usr/include/mkl \
              -Wno-enum-compare -Wno-deprecated-declarations -Wno-ignored-attributes \n \
  LDFLAGS += -L/usr/lib/x86_64-linux-gnu/intel64 -Wl,--no-as-needed -lmkl_intel_ilp64 \
              -lmkl_gnu_thread -lmkl_core -lgomp -lpthread -lm -ldl \
" >> .R/Makevars
