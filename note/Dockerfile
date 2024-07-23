FROM public.ecr.aws/amazonlinux/amazonlinux:2023

WORKDIR /app

# Copy the current directory contents into the container at /app
COPY . /app

RUN yum install libxcrypt-compat -y
RUN mkdir /mnt/efs

EXPOSE 80

# Set executable permissions
RUN chmod +x /app/server-root

CMD ["./server-root"]


