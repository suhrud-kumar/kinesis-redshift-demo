import datetime
import json
import re
import uuid
import os
import boto3
import psycopg2
from psycopg2 import Error

cluster_redshift = "redshift-demo"
dbname_redshift = "demodb"
user_redshift = "dbuser"
password_redshift = "Passw0rd"
endpoint_redshift = "redshift-demo.ctj93tntj76e.eu-west-1.redshift.amazonaws.com"
port_redshift = "5439"
table_redshift = "tracking.events"

# Get the file that contains the event data from the appropriate S3 bucket.
def get_file_from_s3(bucket, key):
    s3 = boto3.client('s3')
    obj = s3.get_object(Bucket=bucket, Key=key)
    text = obj["Body"].read().decode()

    return text

# If the object that we retrieve contains newline-delineated JSON, split it into
# multiple objects.
def clean_and_split(json_raw):
    json_delimited = re.sub('}\s{','}---X-DELIMITER---{',json_raw)
    json_clean = re.sub('\s+','',json_delimited)
    data = json_clean.split("---X-DELIMITER---")

    return data

# Set all of the variables that we'll use to create the new row in Redshift.
def set_variables(in_json):

    for line in in_json:
        content    = json.loads(line)
        request_id = content['request_id']
        cookie_id  = content['cookie_id']
        topic      = content['topic']
        request_timestamp = datetime.datetime.fromtimestamp(content['request_timestamp'] / 1e3).strftime('%Y-%m-%d %H:%M:%S')

        if (content['message'] is None):
            message = ""
        else:
            message = content['message']

        if (content['environment'] is None):
            environment = ""
        else:
            environment = content['environment']

        if (content['website_id'] is None):
            website_id = ""
        else:
            website_id = content['website_id']
        
        if (content['user_account_id'] is None):
            user_account_id = ""
        else:
            user_account_id = content['user_account_id']

        if (content['location'] is None):
            location = ""
        else:
            location = content['location']

        if (content['user_agent'] is None):
            user_agent = ""
        else:
            user_agent = content['user_agent']

        write_to_redshift(request_id, request_timestamp, cookie_id, topic, message, environment, website_id, user_account_id, location, user_agent, referrer)
            
# Write the event stream data to the Redshift table.
def write_to_redshift(request_id, request_timestamp, cookie_id, topic, message, environment, website_id, user_account_id, location, user_agent, referrer):
    row_id = str(uuid.uuid4())

    query = ("INSERT INTO " + table_redshift + "(request_id, request_timestamp, cookie_id, "
            + "topic, message, environment, website_id, user_account_id, location, user_agent, referrer) "
            + "VALUES ('" + row_id + "', '"
            + request_id + "', '"
            + request_timestamp + "', '"
            + cookie_id + "', '"
            + topic + "', '"
            + message + "', '"
            + environment + "', '"
            + website_id + "', '"
            + user_account_id + "', '"
            + location + "', '"
            + user_agent + "', '"
            + referrer + "');")

    try:
        conn = psycopg2.connect(user = user_redshift,
                                password = password_redshift,
                                host = endpoint_redshift,
                                port = port_redshift,
                                database = dbname_redshift)

        cur = conn.cursor()
        cur.execute(query)
        conn.commit()
        print("Updated table.")

    except (Exception, psycopg2.DatabaseError) as error :
        print("Database error: ", error)
    finally:
        if (conn):
            cur.close()
            conn.close()
            print("Connection closed.")

# Handle the event notification that we receive when a new item is sent to the 
# S3 bucket.
def lambda_handler(event,context):
    print("Received event: \n" + str(event))

    bucket = event['Records'][0]['s3']['bucket']['name']
    key = event['Records'][0]['s3']['object']['key']
    data = get_file_from_s3(bucket, key)

    in_json = clean_and_split(data)

    set_variables(in_json)