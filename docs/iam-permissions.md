# IAM Permissions

ZeroNAT uses an IAM Instance Profile. The agent never stores AWS credentials on
disk — it uses the instance metadata service (IMDS) exclusively.

The Terraform module creates this policy automatically. If you manage IAM
separately, use the policy documents below.

---

## Permissions reference

| Permission | When used | Why |
|---|---|---|
| `ec2:DescribeInstances` | Boot, then every 60 s | Reads the group tag on its own instance and discovers the peer node |
| `ec2:DescribeRouteTables` | Boot | Finds the route tables to manage by their group tag |
| `ec2:ReplaceRoute` | Failover | Updates `0.0.0.0/0` to point at the new active node's ENI |
| `ec2:CreateRoute` | Boot (if needed) | Creates the initial `0.0.0.0/0` route if none exists |
| `cloudwatch:GetMetricData` | Periodically | Reads CPU credit metrics for T-series instance monitoring |

The `cloudwatch:GetMetricData` permission is always included. It does not incur
any AWS cost for the metric reads the agent performs.

---

## Base policy (both single and cluster mode)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "RouteManagement",
      "Effect": "Allow",
      "Action": [
        "ec2:DescribeInstances",
        "ec2:DescribeRouteTables",
        "ec2:ReplaceRoute",
        "ec2:CreateRoute"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatchMetrics",
      "Effect": "Allow",
      "Action": [
        "cloudwatch:GetMetricData"
      ],
      "Resource": "*"
    }
  ]
}
```

---

## Optional: CloudWatch Logs

Added automatically by the Terraform module when `cloudwatch_log_group` is set.
If you manage IAM separately and want log shipping, add this statement:

```json
{
  "Sid": "CloudWatchLogs",
  "Effect": "Allow",
  "Action": [
    "logs:CreateLogGroup",
    "logs:CreateLogStream",
    "logs:PutLogEvents",
    "logs:DescribeLogStreams"
  ],
  "Resource": "arn:aws:logs:*:*:log-group:/<your-log-group-prefix>/*:*"
},
{
  "Sid": "SSMGetCWAgentConfig",
  "Effect": "Allow",
  "Action": [
    "ssm:GetParameter"
  ],
  "Resource": "arn:aws:ssm:*:*:parameter/<your-name>/cloudwatch-agent-config"
}
```

Replace `<your-log-group-prefix>` and `<your-name>` with the values you pass as
`cloudwatch_log_group` and `name` in the Terraform module.

---

## Trust policy (EC2 assume role)

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
```

---

## Why `Resource: "*"` on EC2 Describe and Route actions

AWS does not support resource-level restrictions on most `ec2:Describe*` calls.
The agent filters results at the application level using the VPC ID and group
tag, so only route tables and instances in the same VPC are acted on.

`ec2:ReplaceRoute` and `ec2:CreateRoute` do support resource-level conditions
but only by route table ARN. The Terraform module does have the route table IDs
available, and a future module version may scope these to the specific route
tables. For now, the policy is scoped by the agent's own logic — it only calls
`ReplaceRoute` on the route tables it discovered via its own group tag.

---

## Using an existing instance profile

If your organisation manages IAM centrally, set `iam_instance_profile_name` in
the Terraform module and the module will skip creating any IAM resources:

```hcl
module "zeronat" {
  # ...
  iam_instance_profile_name = "my-existing-profile"
}
```

Ensure the existing profile's policy includes all permissions listed above.
