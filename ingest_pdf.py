import os
import glob
import fitz  # PyMuPDF
import ollama
from qdrant_client import QdrantClient
from qdrant_client.models import Distance, VectorParams, PointStruct
import uuid

# Configuration
FILES_DIR = "/files"
OLLAMA_BASE_URL = os.environ.get("OLLAMA_BASE_URL", "http://ollama:11434")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://qdrant:6333")
COLLECTION_NAME = "n8n_knowledge"
EMBEDDING_MODEL = "nomic-embed-text"
CHUNK_SIZE = 1000
CHUNK_OVERLAP = 200

print(f"🔄 Initializing Qdrant client at {QDRANT_URL}...")
q_client = QdrantClient(url=QDRANT_URL)

print(f"🔄 Initializing Ollama client at {OLLAMA_BASE_URL}...")
o_client = ollama.Client(host=OLLAMA_BASE_URL)

# Ensure collection exists
try:
    if not q_client.collection_exists(COLLECTION_NAME):
        print(f"📦 Creating collection '{COLLECTION_NAME}'...")
        q_client.create_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=VectorParams(size=768, distance=Distance.COSINE), # nomic-embed-text uses 768 dims
        )
    else:
        print(f"✅ Collection '{COLLECTION_NAME}' already exists.")
except Exception as e:
     print(f"⚠️ Error checking/creating collection: {e}")


def get_pdf_files():
    return glob.glob(os.path.join(FILES_DIR, "*.pdf"))

def extract_text_from_pdf(filepath):
    print(f"📄 Reading {filepath}...")
    doc = fitz.open(filepath)
    text = ""
    for page in doc:
        text += page.get_text()
    return text

def chunk_text(text, chunk_size, overlap):
    chunks = []
    start = 0
    while start < len(text):
        end = start + chunk_size
        chunks.append(text[start:end])
        start += chunk_size - overlap
    return chunks

def process_pdfs():
    pdf_files = get_pdf_files()
    if not pdf_files:
        print(f"ℹ️ No PDFs found in {FILES_DIR}.")
        return

    print(f"🔍 Found {len(pdf_files)} PDF(s).")
    
    for filepath in pdf_files:
        filename = os.path.basename(filepath)
        text = extract_text_from_pdf(filepath)
        chunks = chunk_text(text, CHUNK_SIZE, CHUNK_OVERLAP)
        
        print(f"✂️  Chunked '{filename}' into {len(chunks)} pieces.")
        
        points = []
        for i, chunk in enumerate(chunks):
            # Generate embedding
            try:
                response = o_client.embeddings(model=EMBEDDING_MODEL, prompt=chunk)
                embedding = response['embedding']
                
                # Create Qdrant point
                point_id = str(uuid.uuid4())
                points.append(
                    PointStruct(
                        id=point_id,
                        vector=embedding,
                        payload={
                            "source": filename,
                            "chunk_index": i,
                            "text": chunk
                        }
                    )
                )
            except Exception as e:
                print(f"❌ Error embedding chunk {i} of {filename}: {e}")
                
        if points:
            print(f"⬆️  Uploading {len(points)} vectors to Qdrant...")
            q_client.upsert(
                collection_name=COLLECTION_NAME,
                points=points
            )
            print(f"✅ Successfully ingested '{filename}'.")

if __name__ == "__main__":
    process_pdfs()
    print("🎉 Ingestion complete!")
