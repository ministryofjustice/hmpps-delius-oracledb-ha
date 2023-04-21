FROM oraclelinux:7-slim

RUN groupadd oinstall

RUN useradd oracle -g oinstall

RUN chown -R oracle:oinstall /home/oracle

RUN yum install -y binutils compat-libcap1 compat-libstdc++-33 compat-libstdc++ gcc gcc-c++ glibc glibc-devel ksh libaio libaio-devel libgcc libstc++ libstc++-devel libXi libXtst make sysstat unzip

RUN mkdir -p /u01/app/oracle/product/19.0.0.0/client && \
    mkdir -p /u01/software/19c && \
    chown -R oracle:oinstall /u01

COPY --chown=oracle:oinstall LINUX.X64_193000_client.zip /u01/software/19c/

USER oracle:oinstall

RUN cd /u01/software/19c/ && unzip LINUX.X64_193000_client.zip
RUN echo "export ORACLE_HOME=/u01/app/oracle/product/19.0.0.0/client" > /home/oracle/.bash_profile
RUN echo "export PATH=\$PATH:\$ORACLE_HOME/bin" >> /home/oracle/.bash_profile
RUN echo "export LD_LIBRARY_PATH=\$ORACLE_HOME/lib:/lib:/usr/lib" >> /home/oracle/.bash_profile
RUN chmod u+x /home/oracle/.bash_profile
RUN . /home/oracle/.bash_profile

COPY client_install.rsp /home/oracle/

# Read loop is used to force build to wait until installer has exited
RUN cd /u01/software/19c/client && \
    ./runInstaller -silent -responseFile /home/oracle/client_install.rsp | \
    while read l ; do echo "$l" ; done

USER root

RUN /u01/app/oraInventory/orainstRoot.sh

USER oracle:oinstall

COPY tnsnames.ora /u01/app/oracle/product/19.0.0.0/client/network/admin/

#RUN  cat /u01/app/oracle/product/19.0.0.0/client/network/admin/tnsnames.ora

#CMD ["sh", "-c", "your-main-command; while true; do sleep 3600; done"]
