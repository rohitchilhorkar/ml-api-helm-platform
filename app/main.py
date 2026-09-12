import os

from fastapi import FastAPI
from pydantic import BaseModel
import joblib

MODEL_VERSION = os.environ.get("MODEL_VERSION", "unknown")
IRIS_CLASSES = ["setosa", "versicolor", "virginica"]

model = joblib.load("model.pkl")

app = FastAPI(title="ml-api")


class IrisFeatures(BaseModel):
    sepal_length: float
    sepal_width: float
    petal_length: float
    petal_width: float


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/predict")
def predict(features: IrisFeatures):
    x = [[
        features.sepal_length,
        features.sepal_width,
        features.petal_length,
        features.petal_width,
    ]]
    prediction = model.predict(x)[0]
    return {
        "prediction": IRIS_CLASSES[prediction],
        "model_version": MODEL_VERSION,
    }
