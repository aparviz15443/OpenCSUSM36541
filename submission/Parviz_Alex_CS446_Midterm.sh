#!/usr/bin/env bash
# ===============================================================
# CS 446 Midterm - OpenCSUSM
# Name: Alexander Parviz
# Campus ID: 202036541
# Lane: cpu
# ===============================================================
#
# WHY I CHOSE THIS LANE
# I chose the CPU lane because Ollama can run the small Qwen model without needing a GPU instance or GPU quota. The GPU lane uses vLLM and a g4dn.xlarge, but it may not launch if the AWS account does not have enough GPU-instance quota, and it costs more per hour than the CPU option in the assignment. 
# The CPU instance, c7i.2xlarge, is listed at an assumed price of $0.357 per hour. At that rate, $100 pays for about 280 hours of instance runtime; however storage and other AWS charges can possibly add to the total.
# I am using Qwen2.5-0.5B through Ollama because it is the smallest model listed for this test and is enough to check that an endpoint can receive a prompt and return a response.
# I will keep the model port private and connect through an SSH tunnel so the inference endpoint is not open to the public internet. 
# The script checks the AWS quota and price information before it creates resources, then at the end it stops and terminates the instance.
#
# ===============================================================
set -euo pipefail

# ------------------------------------------------- MY CHOICES
REGION="us-east-1"
OWNER="parviz"
KEYNAME="opencsusm-parviz-key"
INSTANCE="c7i.2xlarge"
RATE="0.357"
PORT="11434"
MODEL="qwen2.5:0.5b"
DISK="20"
TAG_NAME="OpenCSUSM-${OWNER}"
STATE_DIR="$HOME/.opencsusm-${OWNER}"
KEYFILE="$HOME/.ssh/${KEYNAME}.pem"
mkdir -p "$STATE_DIR" "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

INSTANCE_ID=""
SECURITY_GROUP_ID=""
TUNNEL_PID=""

# Cleanup function closes local SSH tunnel if script exits before the tunnel is closed normally
cleanup_on_exit() {
  local exit_status=$?

  if [[ -n "${TUNNEL_PID:-}" ]]; then
    kill "$TUNNEL_PID" >/dev/null 2>&1 || true
    wait "$TUNNEL_PID" >/dev/null 2>&1 || true
  fi

  # If a command fails after resources have been created, try to remove billable resources.
  if [[ "$exit_status" -ne 0 ]] && command -v aws >/dev/null 2>&1; then
    if [[ -n "${INSTANCE_ID:-}" && "$INSTANCE_ID" != "None" ]]; then
      echo "A command failed; attempting to terminate instance $INSTANCE_ID." >&2
      aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
      aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null 2>&1 || true
    fi

    if [[ -n "${SECURITY_GROUP_ID:-}" && "$SECURITY_GROUP_ID" != "None" ]]; then
      aws ec2 delete-security-group --region "$REGION" --group-id "$SECURITY_GROUP_ID" >/dev/null 2>&1 || true
    fi
  fi
}
trap cleanup_on_exit EXIT

# This helper stops the script with a clear message when required program or AWS setting is missing
need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "ERROR: Required command not found: $1" >&2; exit 1; }
}

# This helper runs a remote command over SSH and retries while new Ubuntu instance finishes starting
remote() {
  local attempt
  for attempt in $(seq 1 40); do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -i "$KEYFILE" "ubuntu@${PUBLIC_DNS}" "$@"; then
      return 0
    fi
    sleep 10
  done
  echo "ERROR: Could not connect to the instance over SSH." >&2
  return 1
}

# This command checks that local machine has tools needed to create AWS resources and to test endpoint
need_cmd aws
need_cmd ssh
need_cmd ssh-keygen
need_cmd curl
need_cmd python3

# Command confirms AWS CLI has usable credentials before script makes any changes
aws sts get-caller-identity --output table

# This command reads the Running On-Demand G and VT instances quota (measured in vCPUs rather than instance count) and CPU instance does not consume this GPU quota
## but  result would show whether the GPU lane could launch, and a low value would require quota increase before choosing lane
aws service-quotas get-service-quota \
  --region "$REGION" \
  --service-code ec2 \
  --quota-code L-DB2E81BA \
  --query '{Quota:Quota.QuotaName,Value:Quota.Value,Unit:Quota.Unit}' \
  --output table || echo "Quota lookup was unavailable; this CPU choice does not require G/VT quota, but verify EC2 limits in the AWS console."

# This command checks selected instance's vCPU count and memory so launch choice is confirmed before resources are created
aws ec2 describe-instance-types \
  --region "$REGION" \
  --instance-types "$INSTANCE" \
  --query 'InstanceTypes[0].{Type:InstanceType,vCPUs:VCpuInfo.DefaultVCpus,MemoryMiB:MemoryInfo.SizeInMiB,Architecture:ProcessorInfo.SupportedArchitectures[0]}' \
  --output table

# Prints assumed hourly rate and approximate runtime covered by $100 before any instance launched
printf 'Assumed On-Demand rate: $%s/hour; $100 covers about %s instance-hours before storage and other charges.\n' "$RATE" "$(python3 -c 'print(int(100 / float(__import__("sys").argv[1])))' "$RATE")"

# This command asks the AWS Pricing API for current Linux shared tenancy price for c7i.2xlarge in US East (N. Virginia) when account has permission to use that API
if PRICE_JSON="$(aws pricing get-products --region us-east-1 --service-code AmazonEC2 \
  --filters Type=TERM_MATCH,Field=instanceType,Value="$INSTANCE" \
            Type=TERM_MATCH,Field=location,Value="US East (N. Virginia)" \
            Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
            Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
            Type=TERM_MATCH,Field=tenancy,Value=Shared \
            Type=TERM_MATCH,Field=capacitystatus,Value=Used \
            Type=TERM_MATCH,Field=operation,Value=RunInstances \
  --max-results 1 --output json 2>/dev/null)"; then
  # This command extracts first returned On Demand USD price so the assumed rate can be compared with AWS's live catalog
  python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); vals=[]; [vals.append(x["pricePerUnit"]["USD"]) for p in d.get("PriceList",[]) for t in json.loads(p).get("terms",{}).get("OnDemand",{}).values() for x in t.get("priceDimensions",{}).values() if "USD" in x.get("pricePerUnit",{})]; print("AWS Pricing API On-Demand USD/hour:", vals[0] if vals else "No price returned")' <<< "$PRICE_JSON"
else
  # Records that live pricing could not be retrieved while retaining stated assignment rate as the estimate
  echo "Live Pricing API lookup was unavailable; continuing with the stated assignment rate of $${RATE}/hour."
fi

# Command finds the default VPC and default subnet so instance has a network with internet access for installation and model download
VPC_ID="$(aws ec2 describe-vpcs --region "$REGION" --filters Name=is-default,Values=true --query 'Vpcs[0].VpcId' --output text)"
[[ -n "$VPC_ID" && "$VPC_ID" != "None" ]] || { echo "ERROR: No default VPC exists in $REGION." >&2; exit 1; }

SUBNET_ID="$(aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)"
[[ -n "$SUBNET_ID" && "$SUBNET_ID" != "None" ]] || { echo "ERROR: No default subnet exists in the default VPC." >&2; exit 1; }

# This command gets launcher's public IPv4 address so SSH rule can be limited to this computer only
MY_IP="$(curl -4 -fsS --max-time 15 https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ "$MY_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: Could not determine a valid public IPv4 address." >&2; exit 1; }

# This command creates dedicated security group before launch so instance never needs to use default group's inbound rules
SECURITY_GROUP_ID="$(aws ec2 create-security-group --region "$REGION" --group-name "${OWNER}-opencsusm-ssh-only" --description "OpenCSUSM SSH only from the launching computer" --vpc-id "$VPC_ID" --query GroupId --output text)"

# This command opens only inbound TCP port 22 to the launcher's /32 address and the Ollama port stays closed to public internet
aws ec2 authorize-security-group-ingress --region "$REGION" --group-id "$SECURITY_GROUP_ID" \
  --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${MY_IP}/32,Description='OpenCSUSM SSH from launcher'}]"

# This command creates an SSH key pair in AWS and saves its private key locally or reuses matching local key if it already exists
if aws ec2 describe-key-pairs --region "$REGION" --key-names "$KEYNAME" >/dev/null 2>&1; then
  [[ -f "$KEYFILE" ]] || { echo "ERROR: Key pair $KEYNAME exists in AWS but $KEYFILE is missing; choose a new KEYNAME or restore the private key." >&2; exit 1; }
  chmod 600 "$KEYFILE"
else
  aws ec2 create-key-pair --region "$REGION" --key-name "$KEYNAME" --query KeyMaterial --output text > "$KEYFILE"
  chmod 600 "$KEYFILE"
fi

# This command resolves the current official Ubuntu 24.04 AMD64 image ID so x86 c7i instance starts from compatible operating system
AMI_ID="$(aws ssm get-parameter --region "$REGION" --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id --query Parameter.Value --output text)"
[[ -n "$AMI_ID" && "$AMI_ID" != "None" ]] || { echo "ERROR: Could not resolve the Ubuntu 24.04 AMI." >&2; exit 1; }

# This command launches tagged c7i.2xlarge with selected Ubuntu AMI, SSH key, 20 GB gp3 root disk, public IP, and SSH-only security group
INSTANCE_ID="$(aws ec2 run-instances --region "$REGION" \
  --image-id "$AMI_ID" \
  --instance-type "$INSTANCE" \
  --key-name "$KEYNAME" \
  --network-interfaces "DeviceIndex=0,SubnetId=${SUBNET_ID},Groups=[${SECURITY_GROUP_ID}],AssociatePublicIpAddress=true,DeleteOnTermination=true" \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={VolumeSize=${DISK},VolumeType=gp3,DeleteOnTermination=true}" \
  --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${TAG_NAME}},{Key=Owner,Value=${OWNER}}]" \
  --query 'Instances[0].InstanceId' --output text)"
echo "Launched instance: $INSTANCE_ID"

# This command waits for EC2 to report new instance as running before script attempts an SSH connection
aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

# This command reads instance's public DNS name which is used as remote host in SSH commands
PUBLIC_DNS="$(aws ec2 describe-instances --region "$REGION" --instance-ids "$INSTANCE_ID" --query 'Reservations[0].Instances[0].PublicDnsName' --output text)"
[[ -n "$PUBLIC_DNS" && "$PUBLIC_DNS" != "None" ]] || { echo "ERROR: The instance does not have a public DNS name." >&2; exit 1; }
echo "Public DNS: $PUBLIC_DNS"

# This command installs Ollama over SSH; its installer configures and starts the Ollama system service on the instance
remote 'bash -s' <<'REMOTE_INSTALL'
set -euo pipefail
sudo apt-get update -y
sudo apt-get install -y curl ca-certificates
curl -fsSL https://ollama.com/install.sh | sh
sudo systemctl enable ollama
sudo systemctl restart ollama
REMOTE_INSTALL

# This command downloads the small Qwen2.5 0.5B model over SSH; Ollama is already listening because its installer started the service, but it cannot answer with this model until the weights are pulled
remote "ollama pull ${MODEL}"

# This command checks through SSH that Ollama's local API is responding and that the selected model is available
remote "bash -lc 'curl -fsS http://127.0.0.1:${PORT}/api/tags && ollama list'"

# This command opens an SSH tunnel in the background, where localhost on this computer is forwarded to localhost on the EC2 instance's Ollama service
ssh -o StrictHostKeyChecking=accept-new -o ExitOnForwardFailure=yes -i "$KEYFILE" -N -L "${PORT}:127.0.0.1:${PORT}" "ubuntu@${PUBLIC_DNS}" &
TUNNEL_PID=$!

# This command waits until the forwarded local endpoint responds before sending the test prompt through the tunnel
for attempt in $(seq 1 30); do
  if curl -fsS "http://127.0.0.1:${PORT}/api/tags" >/dev/null 2>&1; then
    break
  fi
  sleep 2
done
curl -fsS "http://127.0.0.1:${PORT}/api/tags" >/dev/null || { echo "ERROR: The SSH tunnel did not become ready." >&2; exit 1; }

# This command sends the required prompt, 'I am John.', through localhost with temperature 0 and a 20-token output limit; Ollama calls that limit num_predict
curl -fsS "http://127.0.0.1:${PORT}/api/chat" \
  -H 'Content-Type: application/json' \
  -d "{\"model\":\"${MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"I am John.\"}],\"stream\":false,\"options\":{\"num_predict\":20,\"temperature\":0}}"
echo

# This command closes the local SSH tunnel after the test request has finished
kill "$TUNNEL_PID" >/dev/null 2>&1 || true
wait "$TUNNEL_PID" >/dev/null 2>&1 || true
TUNNEL_PID=""

# This command stops the EC2 instance to release compute runtime while noting that the root EBS volume still exists until termination
aws ec2 stop-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-stopped --region "$REGION" --instance-ids "$INSTANCE_ID"
echo "Instance stopped; its root EBS volume still exists until the next step."

# This command terminates the stopped instance, releasing the EC2 instance and deleting its root EBS volume because DeleteOnTermination was set to true
aws ec2 terminate-instances --region "$REGION" --instance-ids "$INSTANCE_ID" >/dev/null
aws ec2 wait instance-terminated --region "$REGION" --instance-ids "$INSTANCE_ID"

# This command deletes the dedicated security group after the instance is gone so the temporary network resource is also removed
aws ec2 delete-security-group --region "$REGION" --group-id "$SECURITY_GROUP_ID"

# This command confirms that no instance with this script's Name tag remains after teardown
aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Name,Values=${TAG_NAME}" --query 'Reservations[].Instances[].{Instance:InstanceId,State:State.Name}' --output table

echo "OpenCSUSM setup, private test, stop, and teardown should all be complete!"
