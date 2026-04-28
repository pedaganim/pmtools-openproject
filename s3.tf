resource "aws_s3_bucket" "openproject_attachments" {
  bucket_prefix = "pmo-openproject-attachments-"
  force_destroy = true # Allows deleting the bucket even if it contains files (useful for destroying the environment)
}

resource "aws_s3_bucket_public_access_block" "openproject_attachments" {
  bucket = aws_s3_bucket.openproject_attachments.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role_policy" "s3_access" {
  name = "openproject-s3-access"
  role = aws_iam_role.ec2_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Effect = "Allow"
        Resource = [
          aws_s3_bucket.openproject_attachments.arn,
          "${aws_s3_bucket.openproject_attachments.arn}/*"
        ]
      }
    ]
  })
}
