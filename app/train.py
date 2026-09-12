"""Train a tiny classifier and pickle it. Run once, at image build time.

Not a real training pipeline (no data versioning, no experiment tracking) -
this exists purely so the API has a real, loadable model artifact to serve.
"""
import joblib
from sklearn.datasets import load_iris
from sklearn.ensemble import RandomForestClassifier

MODEL_VERSION = "v1"

if __name__ == "__main__":
    X, y = load_iris(return_X_y=True)
    model = RandomForestClassifier(n_estimators=50, random_state=42)
    model.fit(X, y)
    joblib.dump(model, "model.pkl")
    print(f"Trained and saved model.pkl (model_version={MODEL_VERSION})")
