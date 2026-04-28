# Provider for us-east-1 (required for CloudFront ACM certificates)
provider "aws" {
  alias  = "us-east-1"
  region = "us-east-1"
}

# Look up the existing Route53 zone for nearborrow.com.au
data "aws_route53_zone" "main" {
  name         = "nearborrow.com.au."
  private_zone = false
}

# Create ACM Certificate for pmo.nearborrow.com.au
resource "aws_acm_certificate" "pmo_cert" {
  provider          = aws.us-east-1
  domain_name       = "pmo.nearborrow.com.au"
  validation_method = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# Create DNS records for ACM validation
resource "aws_route53_record" "pmo_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.pmo_cert.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }

  allow_overwrite = true
  name            = each.value.name
  records         = [each.value.record]
  ttl             = 60
  type            = each.value.type
  zone_id         = data.aws_route53_zone.main.zone_id
}

# Validate the ACM certificate
resource "aws_acm_certificate_validation" "pmo_cert" {
  provider                = aws.us-east-1
  certificate_arn         = aws_acm_certificate.pmo_cert.arn
  validation_record_fqdns = [for record in aws_route53_record.pmo_cert_validation : record.fqdn]
}

# CloudFront Distribution
resource "aws_cloudfront_distribution" "pmo" {
  enabled             = true
  is_ipv6_enabled     = true
  comment             = "OpenProject CloudFront Distribution"
  aliases             = ["pmo.nearborrow.com.au"]
  
  origin {
    domain_name = aws_instance.openproject.public_dns
    origin_id   = "OpenProjectEC2Origin"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # EC2 is currently listening on HTTP:80
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "OpenProjectEC2Origin"

    viewer_protocol_policy = "redirect-to-https"
    
    # Forward all headers, cookies, and query strings to OpenProject
    forwarded_values {
      query_string = true
      headers      = ["*"]
      
      cookies {
        forward = "all"
      }
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.pmo_cert.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.2_2021"
  }
}

# Route 53 Alias Record pointing to CloudFront
resource "aws_route53_record" "pmo_cloudfront" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "pmo.nearborrow.com.au"
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.pmo.domain_name
    zone_id                = aws_cloudfront_distribution.pmo.hosted_zone_id
    evaluate_target_health = false
  }
}

output "cloudfront_domain_name" {
  value = aws_cloudfront_distribution.pmo.domain_name
}
