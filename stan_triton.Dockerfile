FROM debian:bullseye-slim

# Defined only while building
ARG DEBIAN_FRONTEND=noninteractive

# Add non-free repo to install Intel MKL
RUN sed -i -e's/ main/ main contrib non-free/g' /etc/apt/sources.list

RUN apt-get update && apt-get install gnupg -y

# Add CRAN Debian repo and public key so we can install R4.2+
RUN echo "deb http://cloud.r-project.org/bin/linux/debian bullseye-cran40/" >> /etc/apt/sources.list
RUN apt-key adv --keyserver keyserver.ubuntu.com --recv-key '95C0FAF38DB3CCAD0C080A7BDC78B2DDEABC47B7'

RUN apt-get update && apt-get install locales locales-all intel-mkl-full r-base-dev nvidia-opencl-icd \
                                      sudo libcurl4-openssl-dev libv8-dev git cmake \
                                      libxml2-dev clinfo nvidia-cuda-toolkit -y

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
ENV R_MAKEVARS_USER /home/stan_triton/.R/Makevars
ENV R_ENVIRON_USER /home/stan_triton/.Renviron
ENV CMDSTAN /scratch/cs/bayes_ave/.cmdstan-triton/

USER stan_triton
WORKDIR /home/stan_triton

# Create local library for packages
# Local library is prepended to the R_LIBS_USER env so that we can specify external
# libraries when calling the image
RUN mkdir -p R/library

RUN echo " \
  R_LIBS_USER=/home/stan_triton/R/library:\${R_LIBS_USER} \n \
" >> .Renviron

RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  install.packages(c('remotes')); \
  remotes::install_github('stan-dev/cmdstanr', dependencies = TRUE) \
"

RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  install.packages(c('multiverse','remotes','rstan','projpred','brms','tidyverse')) \
"

RUN Rscript -e " \
  Sys.setenv(MAKEFLAGS=paste0('-j', parallel::detectCores())); \
  remotes::install_github('stan-dev/rstan', subdir = 'StanHeaders', \
                          ref = 'experimental'); \
  remotes::install_github('stan-dev/rstan', subdir = 'rstan/rstan', \
                          ref = 'experimental') \
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

