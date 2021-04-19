provider "aws" { # account_one
  region = "eu-west-1"
  profile = "suhrud-aws"
}

provider "aws" {
  region = "eu-west-1"
  alias = "account_two"
  profile = "suhrud-aws"
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 2.0"

  name = "demo-vpc"

  cidr = "10.10.0.0/16"

  azs              = ["eu-west-1a", "eu-west-1b", "eu-west-1c"]
  redshift_subnets = ["10.10.41.0/24", "10.10.42.0/24", "10.10.43.0/24"]

  // Only using this to access redshift db from ec2 instance to create db, tables etc
  public_subnets   = ["10.10.101.0/24", "10.10.102.0/24", "10.10.103.0/24"]

  // To allow redshift to access S3
  // Can also use s3 vpc endpoint instead of this.
  enable_nat_gateway = true
}

module "sg" {
  source  = "terraform-aws-modules/security-group/aws//modules/redshift"
  version = "~> 3.0"

  name   = "demo-redshift"
  vpc_id = module.vpc.vpc_id

  # Allow ingress rules to be accessed only within current VPC
  ingress_cidr_blocks = [module.vpc.vpc_cidr_block]

  # Allow all rules for all protocols
  egress_rules = ["all-all"]
}


resource "aws_redshift_cluster" "redshift_demo" {
  cluster_identifier = "redshift-demo"
  database_name      = "demodb"
  master_username    = "dbuser"
  master_password    = "Passw0rd"
  node_type          = "dc1.large" # can increase based on requirement
  cluster_type       = "single-node"

  vpc_security_group_ids    = [module.sg.this_security_group_id] // only allow access from inside vpc
  cluster_subnet_group_name = aws_redshift_subnet_group.redshift_demo_subnet.name

  publicly_accessible = false
  skip_final_snapshot = true

  iam_roles = [aws_iam_role.redshift_role.arn]
}

resource "aws_redshift_subnet_group" "redshift_demo_subnet" {

  name        = "redshift-demo-subnet"
  description = "Redshift subnet group of redshift-demo cluster"
  subnet_ids  = module.vpc.redshift_subnets

}

resource "aws_s3_bucket" "bucket" {
  bucket = "kinesis-redshift-demo-bucket"
  acl    = "private"
}

resource "aws_iam_role" "redshift_role" {

  name = "redshift_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "redshift.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

// Grant s3 read-only to redshift cluster
// We need s3 access to import any existing data from s3 to redshift db
resource "aws_iam_policy" "redshift_s3_access" {

  name        = "redshift_s3_access"
  path        = "/"
  description = "redshift_s3_access"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:Get*",
          "s3:List*",
        ]
        Effect   = "Allow"
        Resource = ["${aws_s3_bucket.bucket.arn}","${aws_s3_bucket.bucket.arn}/*"]
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "redshift_policy_attachment" {

  role       = aws_iam_role.redshift_role.name
  policy_arn = aws_iam_policy.redshift_s3_access.arn
}


resource "aws_iam_role" "firehose_role" {

  provider = aws.account_two

  name = "firehose_test_role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "firehose.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "s3_access_policy" {
  
  provider = aws.account_two

  name        = "s3_access_policy"
  path        = "/"
  description = "s3_access_policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:AbortMultipartUpload",
          "s3:GetBucketLocation",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:ListBucketMultipartUploads",
          "s3:PutObject"
        ]
        Effect   = "Allow"
        Resource = "${aws_s3_bucket.bucket.arn}/*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "firehose_policy_attachment" {

  provider = aws.account_two

  role       = aws_iam_role.firehose_role.name
  policy_arn = aws_iam_policy.s3_access_policy.arn
}

// Grant firehose (in another account two) access to S3 in account one
resource "aws_s3_bucket_policy" "firehose_access" {
  bucket = aws_s3_bucket.bucket.id

  policy = <<EOT
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Principal": {
              "AWS": "${aws_iam_role.firehose_role.arn}"
          },
          "Action": [
              "s3:AbortMultipartUpload",
              "s3:GetBucketLocation",
              "s3:GetObject",
              "s3:ListBucket",
              "s3:ListBucketMultipartUploads",
              "s3:PutObject"
          ],
          "Resource": [
              "${aws_s3_bucket.bucket.arn}",
              "${aws_s3_bucket.bucket.arn}/*"
          ]
      }
  ]
}
EOT
}



resource "aws_kinesis_firehose_delivery_stream" "demo_stream" {
  
  provider = aws.account_two

  name        = "kinesis-firehose-demo-stream"
  destination = "s3"

  s3_configuration {
    role_arn        = aws_iam_role.firehose_role.arn
    bucket_arn      = aws_s3_bucket.bucket.arn
    buffer_size     = 1
    buffer_interval = 60
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name = "iam_for_lambda"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_policy" "lambda_iam_policy" {
  name        = "lambda_iam_policy"
  path        = "/"
  description = "lambda_iam_policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:CreateNetworkInterface",
          "ec2:DescribeNetworkInterfaces",
          "ec2:DeleteNetworkInterface",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeSubnets",
          "ec2:DescribeVpcs",
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "s3:Get*",
          "s3:List*",

        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attachment" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = aws_iam_policy.lambda_iam_policy.arn
}

resource "aws_lambda_function" "lambda_function" {
  filename      = "lambda_function.zip"
  function_name = "lambda_function"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "lambda_function.lambda_handler"

  source_code_hash = filebase64sha256("lambda_function.zip")

  runtime = "python3.7"

  vpc_config {
    subnet_ids         = module.vpc.redshift_subnets
    security_group_ids = [module.sg.this_security_group_id]
  }

}

resource "aws_lambda_permission" "allow_bucket" {
  statement_id  = "AllowExecutionFromS3Bucket"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.lambda_function.arn
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.bucket.arn
}

resource "aws_s3_bucket_notification" "bucket_notification" {
  bucket = aws_s3_bucket.bucket.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.lambda_function.arn
    events              = ["s3:ObjectCreated:Put"]
  }

  depends_on = [aws_lambda_permission.allow_bucket]
}