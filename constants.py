import os
from dotenv import load_dotenv

load_dotenv()

SIGNING_KEY = os.getenv("SIGNING_KEY")

IS_SIGNING_KEY_IMPLEMENTED = True

CLIENT_ID = os.getenv("CLIENT_ID")

CLIENT_SECRET = os.getenv("CLIENT_SECRET")

API_KEY = os.getenv("API_KEY")

YELLOW_AI_API_KEY = os.getenv("YELLOW_AI_API_KEY")

JAPI_KEY = os.getenv("JAPI_KEY")

JAPI_AUTHORIZATION = os.getenv("JAPI_AUTHORIZATION")

