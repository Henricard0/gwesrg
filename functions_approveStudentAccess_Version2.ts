import { createClientFromRequest } from 'npm:@base44/sdk@0.8.4';

Deno.serve(async (req) => {
  try {
    const base44 = createClientFromRequest(req);
    
    // Verificar autenticação
    const user = await base44.auth.me();
    const isAdmin = user.role === 'admin';
    const isTeacher = user.role === 'teacher' || user.user_role === 'teacher';
    
    if (!user || (!isAdmin && !isTeacher)) {
      return Response.json({ error: 'Não autorizado' }, { status: 401 });
    }

    const { requestId, status, notes } = await req.json();

    // MIGRAÇÃO AUTOMÁTICA: Processar TODAS as solicitações aprovadas sem idioma
    const allApprovedRequests = await base44.asServiceRole.entities.StudentAccessRequest.filter({ 
      status: 'approved' 
    });

    for (const approvedRequest of allApprovedRequests) {
      const [existingUser] = await base44.asServiceRole.entities.User.filter({ 
        email: approvedRequest.user_email 
      });
      
      if (existingUser) {
        const currentLanguages = existingUser.assigned_languages || [];
        
        // Se o usuário não tem o idioma da solicitação aprovada, adicionar
        if (!currentLanguages.includes(approvedRequest.language_code)) {
          await base44.asServiceRole.entities.User.update(existingUser.id, {
            assigned_languages: [...currentLanguages, approvedRequest.language_code]
          });
        }
      }
    }

    // Buscar a solicitação atual
    const [request] = await base44.asServiceRole.entities.StudentAccessRequest.filter({ id: requestId });
    
    if (!request) {
      return Response.json({ error: 'Solicitação não encontrada' }, { status: 404 });
    }

    // Se for aprovação, adicionar o idioma ao usuário
    if (status === 'approved') {
      const [targetUser] = await base44.asServiceRole.entities.User.filter({ email: request.user_email });
      
      if (targetUser) {
        const currentLanguages = targetUser.assigned_languages || [];
        const updatedLanguages = currentLanguages.includes(request.language_code)
          ? currentLanguages
          : [...currentLanguages, request.language_code];

        await base44.asServiceRole.entities.User.update(targetUser.id, {
          assigned_languages: updatedLanguages
        });
      }
    }

    // Atualizar a solicitação
    await base44.asServiceRole.entities.StudentAccessRequest.update(requestId, {
      status,
      teacher_notes: notes,
      approved_by: user.email
    });

    return Response.json({ 
      success: true,
      message: status === 'approved' ? 'Aluno aprovado e acesso concedido!' : 'Solicitação rejeitada'
    });

  } catch (error) {
    console.error('Error:', error);
    return Response.json({ error: error.message }, { status: 500 });
  }
});