import json, os, requests
QURL=os.getenv("QDRANT_URL","http://qdrant:6333")
COL=os.getenv("QDRANT_COLLECTION","i18n_embeddings")
PATH=os.getenv("SEED_PATH","/work/seed_50.json")
MODEL=os.getenv("MODEL_NAME","sentence-transformers/paraphrase-multilingual-MiniLM-L12-v2")
from sentence_transformers import SentenceTransformer
items=json.load(open(PATH,"r",encoding="utf-8"))
texts=[]; ids=[]; payloads=[]
for i,it in enumerate(items):
  l=it["lsid"]; tr=it["translations"]; txt=f"{l} :: "+" | ".join([tr.get(k,"") for k in ("fr","en","de","it","es")])
  texts.append(txt); ids.append(i+1); payloads.append({"lsid":l,"translations":tr})
vecs=SentenceTransformer(MODEL).encode(texts, normalize_embeddings=True).tolist()
points=[{"id":pid,"vector":v,"payload":pl} for pid,v,pl in zip(ids,vecs,payloads)]
r=requests.put(f"{QURL}/collections/{COL}/points?wait=true", json={"points":points}, timeout=300); r.raise_for_status()
print("Upserted:",len(points))
