import json
import urllib.parse
import boto3

print('Loading function')

s3 = boto3.client('s3')


def lambda_handler(event, context):
    #print("Received event: " + json.dumps(event, indent=2))

    # Get the object from the event and show its content type
    bucket = "jnk-todo-tf"
    key = "todo-data"
    try:
        response = s3.get_object(Bucket=bucket, Key=key)
        json_data = response["Body"].read().decode("utf-8")
        json_content = json.loads(json_data)
        print(json_content)
        return {
            'statusCode': 200,
            'body': json_content
        }
        
    except Exception as e:
        print(e)
        print('Error getting object {} from bucket {}. Make sure they exist and your bucket is in the same region as this function.'.format(key, bucket))
        raise e