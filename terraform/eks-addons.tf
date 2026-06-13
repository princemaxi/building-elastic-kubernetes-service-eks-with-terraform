# Make sure you still have this data block somewhere to get your AWS account ID!
# data "aws_caller_identity" "current" {}

# 1. Create the IAM Role for the CSI Driver
resource "aws_iam_role" "ebs_csi_driver_role" {
  name = "AmazonEKS_EBS_CSI_DriverRole"

  # This trust policy allows the EKS cluster to assume this role via OIDC
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          # References the OIDC output directly from your EKS module
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            # References the OIDC output directly from your EKS module
            "${replace(module.eks.cluster_oidc_issuer_url, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

# 2. Attach the official AWS managed policy for EBS CSI to the role
resource "aws_iam_role_policy_attachment" "ebs_csi_driver_policy_attachment" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = aws_iam_role.ebs_csi_driver_role.name
}

# 3. Finally, install the EKS Add-on using the role we just created
resource "aws_eks_addon" "ebs_csi_driver" {
  # This implicit dependency tells Terraform to wait for the module to finish!
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = aws_iam_role.ebs_csi_driver_role.arn

  # Ensure the role and policy exist before trying to create the addon
  depends_on = [
    aws_iam_role_policy_attachment.ebs_csi_driver_policy_attachment
  ]
}
