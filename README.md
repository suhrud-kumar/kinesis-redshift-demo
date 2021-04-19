# kinesis-redshift-demo

This module creates a ETL pipeline that processes events from Kinesis Firehose in one AWS account to Redshift cluster in another account that is not publicly accessible.

Architecture:
1. Firehose delivers events to S3 destination in different account where Redshift resides.
2. Upon events delivering to S3, we configure s3 event notification to trigger a Lambda function that can process the events.
3. This Lambda resides in same vpc as Redshift and can import records from S3 and store them in Redshift DB.
4. We can also use copy command to load/import any existing data from S3 to Redshift using this module.
