FROM oraclelinux:7-slim

RUN groupadd oinstall

RUN useradd oracle -g oinstall

RUN chown -R oracle:oinstall /home/oracle && \
    usermod -d /home/oracle oracle && \
    usermod -s /bin/bash oracle

RUN yum install -y binutils compat-libcap1 compat-libstdc++-33 compat-libstdc++ gcc gcc-c++ glibc glibc-devel ksh libaio libaio-devel libgcc libstc++ libstc++-devel libXi libXtst make sysstat unzip vi

RUN mkdir -p /u01/app/oracle/product/19.0.0.0/client && \
    mkdir -p /u01/software/19c && \
    chown -R oracle:oinstall /u01

COPY --chown=oracle:oinstall LINUX.X64_193000_client.zip /u01/software/19c/

USER oracle:oinstall

WORKDIR /u01/software/19c

RUN unzip LINUX.X64_193000_client.zip

WORKDIR /home/oracle

RUN echo "export ORACLE_HOME=/u01/app/oracle/product/19.0.0.0/client" > .bash_profile
RUN echo "export PATH=\$PATH:\$ORACLE_HOME/bin" >> .bash_profile
RUN echo "export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib" >> .bash_profile
RUN chmod u+x .bash_profile
RUN . /home/oracle/.bash_profile

COPY client_install.rsp /home/oracle/

WORKDIR /u01/software/19c/client

# Read loop is used to force build to wait until installer has exited
RUN ./runInstaller -silent -responseFile /home/oracle/client_install.rsp | \
    while read l ; do echo "$l" ; done

RUN rm /u01/software/19c/LINUX.X64_193000_client.zip

USER root

RUN /u01/app/oraInventory/orainstRoot.sh

USER oracle:oinstall

COPY tnsnames.ora /u01/app/oracle/product/19.0.0.0/client/network/admin/

WORKDIR /home/oracle

CMD ["sh", "-c", "your-main-command; while true; do sleep 3600; done"]
