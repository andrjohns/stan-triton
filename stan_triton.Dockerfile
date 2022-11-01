FROM debian:bullseye-slim

# Defined only while building
ARG DEBIAN_FRONTEND=noninteractive

# Add non-free repo to install Intel MKL
RUN sed -i -e's/ main/ main contrib non-free/g' /etc/apt/sources.list

RUN apt-get update && apt-get install gnupg -y

# Add CRAN Debian repo and public key so we can install R4.2+
RUN echo "deb http://cloud.r-project.org/bin/linux/debian bullseye-cran40/" >> /etc/apt/sources.list
RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-key '95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7'

RUN apt-get update && apt-get install intel-mkl-full r-base-dev nvidia-opencl-icd \
                                      sudo libcurl4-openssl-dev libv8-dev git \
                                      libxml2-dev clinfo nvidia-cuda-toolkit -y

# Specify that the MKL should provide the Matrix algebra libraries for the system
RUN update-alternatives --install /usr/lib/x86_64-linux-gnu/libblas.so.3 \
                                  libblas.so.3-x86_64-linux-gnu \
                                  /usr/lib/x86_64-linux-gnu/libmkl_rt.so 150

RUN update-alternatives --install /usr/lib/x86_64-linux-gnu/liblapack.so.3 \
                                  liblapack.so.3-x86_64-linux-gnu \
                                  /usr/lib/x86_64-linux-gnu/libmkl_rt.so 150

RUN echo " \
  MKL_INTERFACE_LAYER=GNU,LP64 \n \
  MKL_THREADING_LAYER=GNU \n \
  HOME=/home/stan_triton \n \
  R_LIBS_USER=/home/stan_triton/R/library \n \
  R_MAKEVARS_USER=/home/stan_triton/.R/MAKEVARS \n \
  CMDSTAN=/home/stan_triton/.cmdstan/cmdstan-2.30.1 \n \
" >> /etc/profile

RUN adduser --disabled-password --gecos '' stan_triton
RUN adduser stan_triton sudo
RUN echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

ARG R_LIBS_USER=/home/stan_triton/R/library
ARG MKL_INTERFACE_LAYER=GNU,LP64
ARG MKL_THREADING_LAYER=GNU

USER stan_triton
WORKDIR /home/stan_triton

# Create R Makevars file with compiler optimisations and linker flags for
# the Intel MKL and TBB libraries
RUN mkdir .R
RUN echo " \
  CXXFLAGS += -O3 -march=native -mtune=native -DMKL_ILP64 -m64 \
              -Wno-enum-compare -Wno-deprecated-declarations -Wno-ignored-attributes \n \
  CXX14FLAGS += -O3 -march=native -mtune=native -DMKL_ILP64 -m64 \
              -Wno-enum-compare -Wno-deprecated-declarations -Wno-ignored-attributes \n \
  LDFLAGS += -L/usr/lib/x86_64-linux-gnu/intel64 -Wl,--no-as-needed -lmkl_intel_ilp64 \
              -lmkl_tbb_thread -lmkl_core -lpthread -lm -ldl  -Wl,-L,'/usr/lib/x86_64-linux-gnu/' \
              -Wl,-rpath,'/usr/lib/x86_64-linux-gnu/' -Wl,--disable-new-dtags -ltbb \
" >> .R/Makevars

# Create local library for packages and make sure R is aware we're linking to the TBB
# Local library is prepended to the R_LIBS_USER env so that we can specify external
# libraries when calling the image
RUN mkdir -p R/library

# RcppEigen won't install with MKL defined, install first and then define
# TODO(Andrew) open RcppEigen PR to fix
RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  install.packages('RcppEigen') \
"

RUN echo " \
  CXXFLAGS += -DEIGEN_USE_MKL_ALL -I/usr/include/mkl \n \
  CXX14FLAGS += -DEIGEN_USE_MKL_ALL -I/usr/include/mkl \
" >> .R/Makevars

RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  install.packages('remotes', repos = 'https://cloud.r-project.org'); \
  remotes::install_github('stan-dev/cmdstanr', dependencies = TRUE) \
"

RUN Rscript -e " \
  cmdstanr::install_cmdstan(cores = parallel::detectCores()); \
  cmdstanr::cmdstan_make_local(cpp_options = list( \
    'CXXFLAGS += -O3 -march=native -mtune=native -DEIGEN_USE_MKL_ALL -I/usr/include/mkl \
                  -Wno-enum-compare -Wno-deprecated-declarations -Wno-ignored-attributes \
                  -DMKL_ILP64 -m64', \
    'LDFLAGS += -L/usr/lib/x86_64-linux-gnu/intel64 -Wl,--no-as-needed \
                -lmkl_intel_ilp64 -lmkl_tbb_thread -lmkl_core -lpthread -lm -ldl', \
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

RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  install.packages('shiny', repos = 'https://cloud.r-project.org'); \
  install.packages(c('tidyverse','brms','furrr', 'multiverse'), \
                   repos = 'https://cloud.r-project.org') \
"
