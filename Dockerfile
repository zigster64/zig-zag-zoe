#FROM alpine
FROM scratch

# Copy in the files to make up the container
WORKDIR /app
COPY ./zig-out/bin/zig-zag-zoe .

# Run the program
ENTRYPOINT ["./zig-zag-zoe"]
