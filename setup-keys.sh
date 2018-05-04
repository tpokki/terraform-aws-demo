#/bin/sh

# default passhphares is empty
PASSPHARE=${1:-""}

echo -n "aws_access_key_id: "
read ACCESS_KEY

echo -n "aws_secret_access_key: "
read SECRET_KEY

echo "Creating AWS credentials file ..."


mkdir -p ./keys
cat <<EOF > ./keys/aws-credentials
[default]
aws_access_key_id = ${ACCESS_KEY}
aws_secret_access_key = ${SECRET_KEY}
EOF


ssh-keygen -b 4096 -C "AWS deployer" -f ./keys/aws-deployer -N "$PASSPHARE"
