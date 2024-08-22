FROM public.ecr.aws/amazonlinux/amazonlinux:2023

WORKDIR /app

# Copy the current directory contents into the container at /app
COPY . /app

RUN yum install libxcrypt-compat -y
RUN wget https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem
RUN mkdir /mnt/efs
RUN export AWS_DEFAULT_REGION=us-east-1



EXPOSE 80



RUN chmod +x /app/server-root

CMD ["./server-root"]


