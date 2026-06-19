FROM minio/minio:RELEASE.2025-09-07T16-13-09Z-cpuv1

ENTRYPOINT mkdir -p /data/$STORAGE_S3_BUCKET && exec minio server /data --console-address :9001