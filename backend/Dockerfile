FROM swift:6.3-noble
WORKDIR /app
COPY Package.* ./
RUN swift package resolve
COPY Sources Sources
RUN swift build -c release --jobs 4
EXPOSE 8080
CMD [".build/release/Marketplace", "serve", "--hostname", "0.0.0.0", "--port", "8080"]
