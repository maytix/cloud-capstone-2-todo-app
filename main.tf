
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.16"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region  = "us-west-2"
  access_key = ""
  secret_key = ""
}

resource "aws_s3_bucket" "jnk_s3_cap2_tf" {
  bucket = "jnk-todo-tf"
}


# Upload an object
resource "aws_s3_object" "s3_bucket_uploader" {
  bucket = aws_s3_bucket.jnk_s3_cap2_tf.id
  key    = "todo-data"
  source = "./todo-data.json"
  etag = filemd5("./todo-data.json")
}

/* ------- AWS Lambda ------ */
// This is the policy that is added to our role so that 
data "aws_iam_policy_document" "assume_role_lambda" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}
// Defining the lambda role
resource "aws_iam_role" "iam-lambda-role" {
   name = "jnk-capstone2-gettodos-lambda-role-with-s3"
   assume_role_policy = data.aws_iam_policy_document.assume_role_lambda.json
}
// Permissions for policy to allow pulling from S3 buckets
data "aws_iam_policy_document" "lambda-s3-policy" {
  statement {
    effect = "Allow"
    actions = [
        "s3:GetObject"
    ]
    resources = ["arn:aws:s3:::*"]
  }
}

// Defining the policy to pull from S3 buckets using the permissions defined above in data
resource "aws_iam_policy" "lambda-s3-policy"{
  name = "JnkLambdaS3ExecutionPolicy"
  description = "A policy used by lambda functions to gain access to s3 buckets."
  policy = data.aws_iam_policy_document.lambda-s3-policy.json
}

//Attaching policy to the lambda role
resource "aws_iam_role_policy_attachment" "attach-s3-role" {
  role = aws_iam_role.iam-lambda-role.name
  policy_arn = aws_iam_policy.lambda-s3-policy.arn
}

// Where to find the code for the lambda 
data "archive_file" "lambda-zip" {
  type        = "zip"
  source_file = "./resources/lambda.py"
  output_path = "./resources/lambda_function.zip"
}

// The definition of the lambda function
resource "aws_lambda_function" "lambda-create" {
  function_name    = "jnk-todo-init-tf"
  filename         = data.archive_file.lambda-zip.output_path
  source_code_hash = data.archive_file.lambda-zip.output_base64sha256
  role             = aws_iam_role.iam-lambda-role.arn
  handler          = "lambda.lambda_handler"
  runtime          = "python3.9"
}

/* ------- ECR Repo ------ */
resource "aws_ecr_repository" "jnk-tf-cp2-ecr-repo" {
  name = "jnk-tf-cp2-ecr-repo"
}

/* ------- CodeBuild Project ------ */
resource "aws_iam_role" "codebuild-ecr-role" {
  name               = "jnk-tf-cp2-cb-role"
  assume_role_policy = data.aws_iam_policy_document.assume-codebuild-policy.json
}

// Permissions for policy to allow CodeBuild to assume roles
data "aws_iam_policy_document" "assume-codebuild-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

//Policy that is defined in a json string that gives required permissions for codebuild
resource "aws_iam_role_policy" "codebuild-policy" {
  role = aws_iam_role.codebuild-ecr-role.id

  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline_bucket.arn}",
        "${aws_s3_bucket.codepipeline_bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ecs:UpdateService"
      ],
      "Resource": [
        "*"
      ]
    }
  ]
}
POLICY
}

// Defines and creates the policy for the ECR
resource "aws_iam_role_policy_attachment" "codebuild-ecr-policy" {
  role       = aws_iam_role.codebuild-ecr-role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

//Defines and creates the codebuild project
resource "aws_codebuild_project" "jnk-tf-cp2-cb-create" {
  name         = "jnk-tf-cp2-codebuild"
  description  = "jnk-tf-codebuild-project"
  service_role = aws_iam_role.codebuild-ecr-role.arn

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:3.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    privileged_mode = true

    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = "962804699607"
    }
    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = "us-west-2"
    }
    environment_variable {
      name  = "IMAGE_REPO_NAME"
      value = aws_ecr_repository.jnk-tf-cp2-ecr-repo.id
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
    environment_variable {
      name  = "CLUSTER_NAME"
      value = aws_ecs_cluster.jnk-tf-cp2-cluster.id
    }
    environment_variable {
      name  = "SERVICE_NAME"
      value = aws_ecs_service.jnk-tf-cp2_service.id
    }
  }

  source {
    type            = "GITHUB"
    location        = "https://github.com/maytix/cloud-capstone-2-todo-app.git"
    git_clone_depth = 1
  }
}

/* ------- CodePipeline ------ */
resource "aws_codepipeline" "jnk-tf-cp2-cp-create" {
  name     = "jnk-tf-cp2-codepipeline"
  role_arn = aws_iam_role.codepipeline-service-role.arn

  artifact_store {
    location = aws_s3_bucket.codepipeline_bucket.bucket
    type     = "S3"
  }

  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      run_order        = 1
      output_artifacts = ["source_output"]

      configuration = {
        "ConnectionArn"    = aws_codestarconnections_connection.jnk-tf-cp2-connection.arn
        "FullRepositoryId" = "maytix/cloud-capstone-2-todo-app" //replace
        "BranchName"       = "master"
      }
    }
  }

  stage {
    name = "Build"

    action {
      name            = "Build"
      category        = "Build"
      owner           = "AWS"
      provider        = "CodeBuild"
      input_artifacts = ["source_output"]
      version         = "1"
  
      configuration = {
        "ProjectName" = aws_codebuild_project.jnk-tf-cp2-cb-create.id
      }
    }
  }

  stage {
    name = "Deploy"

    action {
      name            = "Deploy"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "CodeDeploy"
      input_artifacts = ["build_output"]
      version         = "1"

      configuration = {
        ActionMode     = "REPLACE_ON_FAILURE"
        Capabilities   = "CAPABILITY_AUTO_EXPAND,CAPABILITY_IAM"
        OutputFileName = "CreateStackOutput.json"
        StackName      = "MyStack"
        TemplatePath   = "build_output::sam-templated.yaml"
      }
    }
  }
}

resource "aws_s3_bucket" "codepipeline_bucket" {
  bucket = "jnk-cp-artifact-bucket"
}

resource "aws_s3_bucket_acl" "codepipeline_bucket_acl" {
  bucket = aws_s3_bucket.codepipeline_bucket.id
  acl    = "private"
}

resource "aws_iam_role" "codepipeline-service-role" {
  name               = "jnk-tf-cp2-cp-role"
  assume_role_policy = data.aws_iam_policy_document.assume-codepipeline-policy.json
}

data "aws_iam_policy_document" "assume-codepipeline-policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "codepipeline_policy" {
  name = "codepipeline_policy"
  role = aws_iam_role.codepipeline-service-role.id

  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect":"Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:GetBucketVersioning",
        "s3:PutObjectAcl",
        "s3:PutObject"
      ],
      "Resource": [
        "${aws_s3_bucket.codepipeline_bucket.arn}",
        "${aws_s3_bucket.codepipeline_bucket.arn}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "codestar-connections:UseConnection"
      ],
      "Resource": "${aws_codestarconnections_connection.jnk-tf-cp2-connection.id}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "codebuild:BatchGetBuilds",
        "codebuild:StartBuild"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}

/* ------ CodeStar Connection ------ */
resource "aws_codestarconnections_connection" "jnk-tf-cp2-connection" {
  name          = "jnk-tf-cp2-cs-connection"
  provider_type = "GitHub"
}


# Providing a reference to our default VPC
resource "aws_default_vpc" "default_vpc" {
}

# Providing a reference to our default subnets
resource "aws_default_subnet" "default_subnet_a" {
  availability_zone = "us-west-2a"
}

resource "aws_default_subnet" "default_subnet_b" {
  availability_zone = "us-west-2b"
}

resource "aws_default_subnet" "default_subnet_c" {
  availability_zone = "us-west-2c"
}


resource "aws_ecs_cluster" "jnk-tf-cp2-cluster" {
  name = "jnk-tf-cp2-cluster" # Naming the cluster
}

resource "aws_ecs_task_definition" "jnk-tf-cp2-task" {
  family                   = "jnk-tf-cp2-task" # Naming our first task
  container_definitions    = <<DEFINITION
  [
    {
      "name": "jnk-tf-cp2-task",
      "image": "${aws_ecr_repository.jnk-tf-cp2-ecr-repo.repository_url}",
      "essential": true,
      "portMappings": [
        {
          "containerPort": 3000,
          "hostPort": 3000
        }
      ],
      "memory": 512,
      "cpu": 256
    }
  ]
  DEFINITION
  requires_compatibilities = ["FARGATE"] # Stating that we are using ECS Fargate
  network_mode             = "awsvpc"    # Using awsvpc as our network mode as this is required for Fargate
  memory                   = 512         # Specifying the memory our container requires
  cpu                      = 256         # Specifying the CPU our container requires
  execution_role_arn       = aws_iam_role.ecsTaskExecutionRole.arn
}

resource "aws_iam_role" "ecsTaskExecutionRole" {
  name               = "jnkTaskExecutionRole"
  assume_role_policy = data.aws_iam_policy_document.assume_role_policy.json
}

data "aws_iam_policy_document" "assume_role_policy" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "ecsTaskExecutionRole_policy" {
  role       = aws_iam_role.ecsTaskExecutionRole.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_alb" "application_load_balancer" {
  name               = "jnk-tf-cp2-alb" # Naming our load balancer
  load_balancer_type = "application"
  subnets = [ # Referencing the default subnets
    "${aws_default_subnet.default_subnet_a.id}",
    "${aws_default_subnet.default_subnet_b.id}",
    "${aws_default_subnet.default_subnet_c.id}"
  ]
  # Referencing the security group
  security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
}

# Creating a security group for the load balancer:
resource "aws_security_group" "load_balancer_security_group" {
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allowing traffic in from all sources
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_lb_target_group" "target_group" {
  name        = "jnk-tf-cp2-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_default_vpc.default_vpc.id # Referencing the default VPC
}

resource "aws_lb_target_group" "target_group_2" {
  name        = "jnk-tf-cp2-tg-2"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_default_vpc.default_vpc.id # Referencing the default VPC
}

//Creates a listener
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_alb.application_load_balancer.arn # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    forward{
      target_group { 
        arn = aws_lb_target_group.target_group.arn # Referencing our target group
      }
      target_group { 
        arn = aws_lb_target_group.target_group_2.arn # Referencing our target group
      }
    }
  }
}

//Link the service to the cluster and load balancer on port 3000 using the task
resource "aws_ecs_service" "jnk-tf-cp2_service" {
  name            = "jnk-tf-cp2-service"                        # Naming our first service
  cluster         = aws_ecs_cluster.jnk-tf-cp2-cluster.id       # Referencing our created Cluster
  task_definition = aws_ecs_task_definition.jnk-tf-cp2-task.arn # Referencing the task our service will spin up
  launch_type     = "FARGATE"
  desired_count   = 3 # Setting the number of containers to 3

  deployment_controller {
    type="CODE_DEPLOY"
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.target_group.arn # Referencing our target group
    container_name   = aws_ecs_task_definition.jnk-tf-cp2-task.family
    container_port   = 3000 # Specifying the container port
  }

  network_configuration {
    subnets          = ["${aws_default_subnet.default_subnet_a.id}", "${aws_default_subnet.default_subnet_b.id}", "${aws_default_subnet.default_subnet_c.id}"]
    assign_public_ip = true                                                # Providing our containers with public IPs
    security_groups  = ["${aws_security_group.service_security_group.id}"] # Setting the security group
  }
}


resource "aws_security_group" "service_security_group" {
  ingress {
    from_port = 0
    to_port   = 0
    protocol  = "-1"
    # Only allowing traffic in from the load balancer security group
    security_groups = ["${aws_security_group.load_balancer_security_group.id}"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_codedeploy_app" "jnk_codedeploy_app" {
  compute_platform = "ECS"
  name             = "jnk-cp2-codedeploy-tf"
}


resource "aws_iam_role" "codedeploy_role" {
  name = "jnk-cp2-codedeploy-role-tf"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "codedeploy.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "codedeploy-ecs-policy" {
  role = aws_iam_role.codedeploy_role.id
  policy = <<POLICY
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Resource": [
        "*"
      ],
      "Action": "ecs:DescribeServices"
    }
  ]
}
POLICY
}

resource "aws_iam_role_policy_attachment" "AWSCodeDeployRole" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
  role       = aws_iam_role.codedeploy_role.name
}

resource "aws_codedeploy_deployment_group" "jnk_deployment_group" {
  app_name               = aws_codedeploy_app.jnk_codedeploy_app.name
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  deployment_group_name  = "jnk-cp2-deployment-group"
  service_role_arn       = aws_iam_role.codedeploy_role.arn

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }

    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.jnk-tf-cp2-cluster.name
    service_name = aws_ecs_service.jnk-tf-cp2_service.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.listener.arn]
      }

      target_group {
        name = aws_lb_target_group.target_group.name
      }

      target_group {
        name = aws_lb_target_group.target_group_2.name
      }
    }
  }
}