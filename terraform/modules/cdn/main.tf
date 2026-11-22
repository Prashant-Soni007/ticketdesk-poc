# Free HTTPS: CloudFront in front of the EC2 app with the default *.cloudfront.net certificate (no domain, no ALB).
# Browser -> CloudFront is HTTPS; CloudFront -> EC2 is HTTP on port 80 (EC2 SG only accepts CloudFront's origin-facing IPs).
variable "name" { type = string }
variable "origin_domain" {
  type        = string
  description = "Public DNS name of the EC2 Elastic IP (CloudFront origins must be hostnames, not IPs)"
}
variable "allowed_cidrs" {
  type        = list(string)
  description = "IPv4 CIDRs allowed to use the app (checked on the viewer IP by a CloudFront Function). [\"0.0.0.0/0\"] = everyone"
}

data "aws_cloudfront_cache_policy" "disabled" { name = "Managed-CachingDisabled" }
data "aws_cloudfront_origin_request_policy" "all_viewer" { name = "Managed-AllViewerExceptHostHeader" }
data "aws_cloudfront_response_headers_policy" "security" { name = "Managed-SecurityHeadersPolicy" } # HSTS, nosniff, frame options

# The SG can no longer filter users (traffic arrives from CloudFront), so the IP allow-list moves here.
resource "aws_cloudfront_function" "ip_allow" {
  name    = "${var.name}-ip-allow"
  runtime = "cloudfront-js-2.0"
  comment = "Allow only var.allowed_cidrs"
  publish = true
  code    = <<-EOT
    var ALLOWED = ${jsonencode(var.allowed_cidrs)};
    function toInt(ip) {
      var p = ip.split('.');
      if (p.length !== 4) return null;
      return (((+p[0]) << 24) >>> 0) + ((+p[1]) << 16) + ((+p[2]) << 8) + (+p[3]);
    }
    function inCidr(ip, cidr) {
      var parts = cidr.split('/');
      var bits = parts.length > 1 ? parseInt(parts[1], 10) : 32;
      var a = toInt(ip), b = toInt(parts[0]);
      if (a === null || b === null) return false;
      if (bits === 0) return true;
      var mask = (0xFFFFFFFF << (32 - bits)) >>> 0;
      return ((a & mask) >>> 0) === ((b & mask) >>> 0);
    }
    function handler(event) {
      var ip = event.viewer.ip;
      for (var i = 0; i < ALLOWED.length; i++) {
        if (inCidr(ip, ALLOWED[i])) return event.request;
      }
      return { statusCode: 403, statusDescription: 'Forbidden' };
    }
  EOT
}

#tfsec:ignore:aws-cloudfront-enable-waf
#tfsec:ignore:aws-cloudfront-enable-logging
#tfsec:ignore:aws-cloudfront-use-secure-tls-policy
resource "aws_cloudfront_distribution" "app" {
  #checkov:skip=CKV_AWS_68:POC cost - WAF is ~$5+/month; access is limited by the IP allow-list function
  #checkov:skip=CKV2_AWS_47:No WAF (see above)
  #checkov:skip=CKV_AWS_86:POC cost/noise - access logs not needed; app logs go to CloudWatch
  #checkov:skip=CKV_AWS_174:The free default *.cloudfront.net certificate does not allow choosing a minimum TLS version (needs a custom cert + domain)
  #checkov:skip=CKV2_AWS_42:Custom certificate needs a domain; the default certificate is the free option
  #checkov:skip=CKV_AWS_310:Single EC2 origin by design (no second origin to fail over to)
  #checkov:skip=CKV_AWS_374:No geo restriction needed; viewer IP allow-list is stricter
  #checkov:skip=CKV2_AWS_32:Managed-SecurityHeadersPolicy is attached below
  #checkov:skip=CKV_AWS_305:Dynamic app - "/" is served (redirect to /login) by the origin, not a static object
  enabled         = true
  comment         = "${var.name} HTTPS front door"
  is_ipv6_enabled = false            # keep viewer IPs IPv4 so the IPv4 allow-list applies
  price_class     = "PriceClass_200" # includes India edge locations
  http_version    = "http2"

  origin {
    origin_id   = "ec2"
    domain_name = var.origin_domain
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "http-only" # no certificate on the instance in this POC
      origin_ssl_protocols     = ["TLSv1.2"]
      origin_read_timeout      = 30
      origin_keepalive_timeout = 5
    }
  }

  default_cache_behavior {
    target_origin_id           = "ec2"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id # dynamic app: never cache
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_viewer.id
    response_headers_policy_id = data.aws_cloudfront_response_headers_policy.security.id
    function_association {
      event_type   = "viewer-request"
      function_arn = aws_cloudfront_function.ip_allow.arn
    }
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

output "url" { value = "https://${aws_cloudfront_distribution.app.domain_name}" }
output "distribution_id" { value = aws_cloudfront_distribution.app.id }
output "function_name" { value = aws_cloudfront_function.ip_allow.name }
