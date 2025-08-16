import os, json
from fastapi import FastAPI, Request, HTTPException, Body
from fastapi.responses import PlainTextResponse
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST
import psycopg
from psycopg.rows import dict_row

S = os.getenv("SERVICE_NAME","service")
DB = os.getenv("DATABASE_URL")
app = FastAPI(title=f"SouveraTech {S}")

REQ = Counter("souveratech_requests_total","Requests",["service","route","method","code"])
LAT = Histogram("souveratech_request_duration_seconds","Latency",["service","route","method"])

@app.middleware("http")
async def mw(request: Request, call_next):
  route, method = request.url.path, request.method
  with LAT.labels(S,route,method).time():
    try:
      resp = await call_next(request)
      REQ.labels(S,route,method,resp.status_code).inc()
      return resp
    except Exception:
      REQ.labels(S,route,method,500).inc()
      raise

@app.get("/healthz")
def healthz():
  return {"ok": True, "service": S}

@app.get("/metrics")
def metrics():
  return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)

def conn():
  if not DB: raise RuntimeError("DATABASE_URL missing")
  return psycopg.connect(DB, row_factory=dict_row)

# core-meta
@app.get("/api/meta/objects")
def list_objects():
  if S!="core-meta": return []
  with conn() as c, c.cursor() as cur:
    cur.execute("SELECT name,label,parent_name,version FROM sys_db_object ORDER BY name")
    return cur.fetchall()

@app.post("/api/meta/objects")
def create_object(payload: dict = Body(...)):
  if S!="core-meta": raise HTTPException(404)
  with conn() as c, c.cursor() as cur:
    cur.execute("INSERT INTO sys_db_object(name,label,parent_name) VALUES(%s,%s,%s) ON CONFLICT DO NOTHING",
                (payload["name"], json.dumps(payload.get("label",{})), payload.get("parent","core.work")))
    c.commit(); return {"ok": True}

@app.get("/api/meta/fields")
def list_fields(object: str):
  if S!="core-meta": return []
  with conn() as c, c.cursor() as cur:
    cur.execute("SELECT object_name,name,type,label,required FROM sys_dictionary WHERE object_name=%s ORDER BY name",(object,))
    return cur.fetchall()

@app.post("/api/meta/fields")
def create_field(payload: dict = Body(...)):
  if S!="core-meta": raise HTTPException(404)
  with conn() as c, c.cursor() as cur:
    cur.execute("INSERT INTO sys_dictionary(object_name,name,type,label,required,settings) VALUES(%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING",
                (payload["object"], payload["name"], payload["type"], json.dumps(payload.get("label",{})), bool(payload.get("required",False)), json.dumps(payload.get("settings",{}))))
    c.commit(); return {"ok": True}

# scheduler minimal
@app.get("/api/scheduled_jobs")
def list_jobs():
  if S!="scheduler": return []
  with conn() as c, c.cursor() as cur:
    cur.execute("SELECT job_key,enabled,schedule,action FROM scheduled_jobs ORDER BY job_key")
    return cur.fetchall()
