import json
import boto3
import uuid
import os
from datetime import datetime

# Inicializar cliente de DynamoDB
dynamodb = boto3.resource('dynamodb')
table_name = os.environ.get('TABLE_NAME', 'cerebro_secundario')
table = dynamodb.Table(table_name)

def lambda_handler(event, context):
    try:
        # Extraer el body de la petición HTTP
        body = json.loads(event.get('body', '{}'))
        texto = body.get('texto', '').strip()
        
        if not texto:
            return {'statusCode': 400, 'body': json.dumps({'error': 'No se proporcionó texto'})}

        # Clasificación básica (puedes mejorar esto con IA en el futuro)
        categoria = "Idea"
        if texto.lower().startswith("gasto"):
            categoria = "Gasto"
        elif texto.lower().startswith("tarea"):
            categoria = "Tarea"

        # Crear el item para DynamoDB
        item = {
            'id': str(uuid.uuid4()),
            'fecha': datetime.utcnow().isoformat(),
            'texto': texto,
            'categoria': categoria
        }

        # Guardar en DynamoDB
        table.put_item(Item=item)

        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({'message': '¡Guardado con éxito!', 'item': item})
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Error interno del servidor'})
        }