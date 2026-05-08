import json
import boto3
import uuid
import os
from datetime import datetime

# Inicializar clientes
dynamodb = boto3.resource('dynamodb')
table_name = os.environ.get('TABLE_NAME', 'cerebro_secundario')
table = dynamodb.Table(table_name)

# Cliente de Bedrock
bedrock = boto3.client(service_name='bedrock-runtime', region_name='us-east-1')

def lambda_handler(event, context):
    try:
        # Extraer el body de la petición HTTP
        body = json.loads(event.get('body', '{}'))
        texto = body.get('texto', '').strip()
        
        if not texto:
            return {'statusCode': 400, 'body': json.dumps({'error': 'No se proporcionó texto'})}

        # Prompt para Bedrock (Claude 3.5 Haiku)
        prompt = f"""
You are an intelligent assistant for a "Second Brain" application. The user has captured the following text via voice or typing:

<text>
{texto}
</text>

Please analyze the text and do two things:
1. Determine the category: "Idea", "Task", "Expense", or "Note".
2. Refine the text. If it's an idea, expand on it slightly or polish it. If it's a task, extract the action items clearly. If it's an expense, extract the amount and item. Respond in English or Spanish depending on the language of the input text. Keep the response concise and conversational, as it will be read aloud by Siri.

Output your response strictly as a JSON object with the following keys:
- "category": (The category string)
- "response": (Your refined text and conversational feedback)

JSON Output:
"""

        try:
            # Llamada a Amazon Bedrock
            bedrock_response = bedrock.invoke_model(
                modelId='anthropic.claude-3-5-haiku-20241022-v1:0',
                body=json.dumps({
                    "anthropic_version": "bedrock-2023-05-31",
                    "max_tokens": 300,
                    "temperature": 0.5,
                    "messages": [
                        {
                            "role": "user",
                            "content": prompt
                        }
                    ]
                })
            )
            
            response_body = json.loads(bedrock_response.get('body').read())
            ai_text = response_body.get('content')[0].get('text')
            
            # Limpiar el string JSON devuelto por Claude
            clean_json_str = ai_text.strip()
            if clean_json_str.startswith("```json"):
                clean_json_str = clean_json_str[7:]
            if clean_json_str.startswith("```"):
                clean_json_str = clean_json_str[3:]
            if clean_json_str.endswith("```"):
                clean_json_str = clean_json_str[:-3]
                
            ai_data = json.loads(clean_json_str.strip())
            categoria = ai_data.get('category', 'Idea')
            ai_feedback = ai_data.get('response', 'Guardado en tu segundo cerebro.')
            
        except Exception as ai_error:
            print(f"Error AI: {str(ai_error)}")
            categoria = "Idea"
            ai_feedback = "Guardado con éxito (AI temporalmente no disponible)."

        # Crear el item para DynamoDB
        item = {
            'id': str(uuid.uuid4()),
            'fecha': datetime.utcnow().isoformat(),
            'texto_original': texto,
            'texto_refinado': ai_feedback,
            'categoria': categoria
        }

        # Guardar en DynamoDB
        table.put_item(Item=item)

        # Devolver respuesta a API Gateway
        return {
            'statusCode': 200,
            'headers': {'Content-Type': 'application/json'},
            'body': json.dumps({
                'message': '¡Guardado con éxito!', 
                'ai_response': ai_feedback,
                'item': item
            })
        }

    except Exception as e:
        print(f"Error general: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({'error': 'Error interno del servidor'})
        }