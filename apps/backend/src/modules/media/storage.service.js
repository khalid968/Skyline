import { Injectable, Dependencies, Logger } from '@nestjs/common';
import { ConfigService } from '@nestjs/config';
import {
  S3Client,
  HeadBucketCommand,
  CreateBucketCommand,
  CreateMultipartUploadCommand,
  UploadPartCommand,
  CompleteMultipartUploadCommand,
  AbortMultipartUploadCommand,
  GetObjectCommand,
  DeleteObjectCommand,
} from '@aws-sdk/client-s3';

// The object store (S3 protocol; MinIO in development). It only ever holds
// ciphertext that was encrypted on the phone. It is never exposed to the
// internet: every upload and download goes through the Skyline server, which
// authorises each request against the contact graph.
@Injectable()
@Dependencies(ConfigService)
export class StorageService {
  constructor(config) {
    const s = config.get('storage');
    this.bucket = s.bucket;
    this.client = new S3Client({
      endpoint: `${s.useSsl ? 'https' : 'http'}://${s.endpoint}:${s.port}`,
      region: 'us-east-1',
      forcePathStyle: true,
      credentials: { accessKeyId: s.accessKey, secretAccessKey: s.secretKey },
    });
    this.logger = new Logger('Storage');
  }

  // For the dashboard overview (board 36): is the object store answering?
  async ping() {
    await this.client.send(new HeadBucketCommand({ Bucket: this.bucket }));
  }

  async onModuleInit() {
    try {
      await this.client.send(new HeadBucketCommand({ Bucket: this.bucket }));
    } catch {
      try {
        await this.client.send(
          new CreateBucketCommand({ Bucket: this.bucket }),
        );
        this.logger.log(`created bucket ${this.bucket}`);
      } catch (err) {
        // Media is unavailable until the store is; messaging still works.
        this.logger.error(`object store unavailable: ${err.message}`);
      }
    }
  }

  async startUpload(key) {
    const r = await this.client.send(
      new CreateMultipartUploadCommand({
        Bucket: this.bucket,
        Key: key,
        ContentType: 'application/octet-stream',
      }),
    );
    return r.UploadId;
  }

  async uploadPart(key, uploadId, partNumber, body) {
    const r = await this.client.send(
      new UploadPartCommand({
        Bucket: this.bucket,
        Key: key,
        UploadId: uploadId,
        PartNumber: partNumber,
        Body: body,
        ContentLength: body.length,
      }),
    );
    return r.ETag;
  }

  async completeUpload(key, uploadId, parts) {
    await this.client.send(
      new CompleteMultipartUploadCommand({
        Bucket: this.bucket,
        Key: key,
        UploadId: uploadId,
        MultipartUpload: {
          Parts: parts.map((p) => ({
            PartNumber: p.part_number,
            ETag: p.etag,
          })),
        },
      }),
    );
  }

  async abortUpload(key, uploadId) {
    try {
      await this.client.send(
        new AbortMultipartUploadCommand({
          Bucket: this.bucket,
          Key: key,
          UploadId: uploadId,
        }),
      );
    } catch {
      // already gone
    }
  }

  // Returns { body (a Node stream), contentLength, contentRange }.
  async read(key, range) {
    const r = await this.client.send(
      new GetObjectCommand({ Bucket: this.bucket, Key: key, Range: range }),
    );
    return {
      body: r.Body,
      contentLength: r.ContentLength,
      contentRange: r.ContentRange,
    };
  }

  async remove(key) {
    await this.client.send(
      new DeleteObjectCommand({ Bucket: this.bucket, Key: key }),
    );
  }
}
